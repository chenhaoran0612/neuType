# Meeting Transcription Server 生产部署文档

本文档面向 NeuType 会议转写服务端的生产部署。当前服务端是一个 FastAPI 应用，负责接收 macOS 客户端上传的会议音频分块、落盘保存 artifact、调用 Gradio ASR 后端处理音频，并向客户端返回转写进度与最终分段结果。

---

## 1. 当前生产形态

### 1.1 服务职责

服务端提供以下 HTTP API：

- `POST /api/meeting-transcription/sessions`
  - 创建或复用一个会议转写 session。
- `PUT /api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}`
  - 上传 5 分钟左右的实时音频 chunk。
- `PUT /api/meeting-transcription/sessions/{session_id}/full-audio`
  - 上传完整音频，作为失败或缺块时的 fallback。
- `POST /api/meeting-transcription/sessions/{session_id}/finalize`
  - 标记上传完成，触发服务端按顺序处理。
- `GET /api/meeting-transcription/sessions/{session_id}`
  - 查询处理状态、chunk 结果、最终 transcript。
- `GET /healthz`
  - 健康检查。

### 1.2 进程模型

当前实现采用 **单个 uvicorn 进程内同时运行 API 与后台 worker thread**：

- API 负责接收上传和查询状态。
- 后台 worker 轮询数据库，处理 pending chunk。
- worker 调用 Gradio 后端。
- worker 会生成 speaker anchor WAV / prefix WAV artifact，并把最终结果按绝对时间线写回数据库。

生产部署约束：

- 当前版本建议使用 **1 个 uvicorn worker process**。
- 不要直接用 `--workers N` 横向扩 FastAPI 进程。
  - 多进程会启动多个 in-process worker，增加重复竞争和 SQLite 锁风险。
- 如果后续要水平扩展，应先把 worker 拆成独立进程，并引入明确的任务锁/队列。

---

## 2. 服务器要求

### 2.1 操作系统

推荐：

- Ubuntu 22.04 LTS 或 Ubuntu 24.04 LTS
- Python 3.12+
- systemd
- Nginx 作为反向代理

### 2.2 磁盘

服务会保存：

- 上传的 live chunk WAV
- full audio fallback
- speaker anchor WAV
- prefix WAV
- 数据库文件

建议：

- 数据库目录和 artifact 目录放在持久盘。
- artifact 目录至少预留 50GB 起步；按真实会议量扩容。
- 定期备份数据库。
- artifact 是否长期保留应按隐私策略决定；当前服务端不会自动清理。

### 2.3 网络

服务端需要：

- 对 macOS 客户端暴露 HTTPS。
- 能访问 Gradio ASR backend：
  - 默认：`https://546463aae3e7327f37.gradio.live/`
  - 可通过 `MEETING_TRANSCRIPTION_GRADIO_BASE_URL` 覆盖。

---

## 3. 目录规划

推荐部署路径：

```bash
/opt/neutype/meeting-transcription
├── app/                 # 代码目录
├── .venv/               # Python virtualenv
├── data/
│   └── meeting_transcription.db
├── artifacts/           # 音频和中间产物
└── logs/
```

创建系统用户：

```bash
sudo useradd --system --home /opt/neutype --shell /usr/sbin/nologin neutype
sudo mkdir -p /opt/neutype/meeting-transcription/{app,data,artifacts,logs}
sudo chown -R neutype:neutype /opt/neutype
```

---

## 4. 安装代码和依赖

示例：从仓库部署到 `/opt/neutype/meeting-transcription/app`。

```bash
sudo -u neutype git clone <YOUR_REPO_URL> /opt/neutype/meeting-transcription/app
cd /opt/neutype/meeting-transcription/app/server

sudo -u neutype python3.12 -m venv /opt/neutype/meeting-transcription/.venv
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install --upgrade pip
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install -r requirements.txt
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install "alembic>=1.18,<2.0"
```

如果机器默认没有 Python 3.12：

```bash
python3 --version
```

确认版本满足 `>=3.12` 后再继续。

---

## 5. 环境变量

创建环境文件：

```bash
sudo tee /etc/neutype-meeting-transcription.env >/dev/null <<'EOF'
MEETING_TRANSCRIPTION_DATABASE_URL=sqlite+pysqlite:////opt/neutype/meeting-transcription/data/meeting_transcription.db
MEETING_TRANSCRIPTION_STORAGE_ROOT=/opt/neutype/meeting-transcription/artifacts

MEETING_TRANSCRIPTION_GRADIO_BASE_URL=https://546463aae3e7327f37.gradio.live/
MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS=8192
MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE=0.0
MEETING_TRANSCRIPTION_GRADIO_TOP_P=1.0
MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE=false
MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO=

MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS=1.0
EOF
sudo chmod 640 /etc/neutype-meeting-transcription.env
sudo chown root:neutype /etc/neutype-meeting-transcription.env
```

### 5.1 必填变量

| 变量 | 说明 |
| --- | --- |
| `MEETING_TRANSCRIPTION_DATABASE_URL` | SQLAlchemy DB URL。当前推荐 SQLite 持久文件。 |
| `MEETING_TRANSCRIPTION_STORAGE_ROOT` | artifact 根目录。必须是持久目录。 |
| `MEETING_TRANSCRIPTION_GRADIO_BASE_URL` | Gradio ASR 服务根地址。 |

### 5.2 Worker 参数

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS` | `8192` | Gradio ASR 最大 token。 |
| `MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE` | `0.0` | 采样温度。 |
| `MEETING_TRANSCRIPTION_GRADIO_TOP_P` | `1.0` | top-p。 |
| `MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE` | `false` | 是否采样。 |
| `MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO` | 空 | 传给 ASR 的上下文。 |
| `MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS` | `1.0` | worker 空闲轮询间隔。 |

---

## 6. 数据库迁移

首次部署或升级前执行 Alembic：

```bash
cd /opt/neutype/meeting-transcription/app/server
sudo -u neutype env $(cat /etc/neutype-meeting-transcription.env | xargs) \
  /opt/neutype/meeting-transcription/.venv/bin/python -m alembic upgrade head
```

当前 migration head：

```text
20260420_04
```

验证迁移状态：

```bash
cd /opt/neutype/meeting-transcription/app/server
sudo -u neutype env $(cat /etc/neutype-meeting-transcription.env | xargs) \
  /opt/neutype/meeting-transcription/.venv/bin/python -m alembic current
```

说明：

- 应用启动时也会执行 `Base.metadata.create_all(engine)`，但生产环境仍应显式跑 migration。
- schema 变更上线前必须先备份数据库。

---

## 7. systemd 服务

仓库已提供可复制模板：

```bash
deploy/meeting-transcription/neutype-meeting-transcription.service
deploy/meeting-transcription/neutype-meeting-transcription.env.example
deploy/meeting-transcription/install.sh
```

也可以用辅助脚本安装模板：

```bash
sudo deploy/meeting-transcription/install.sh
```

创建 service：

```bash
sudo tee /etc/systemd/system/neutype-meeting-transcription.service >/dev/null <<'EOF'
[Unit]
Description=NeuType Meeting Transcription Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=neutype
Group=neutype
WorkingDirectory=/opt/neutype/meeting-transcription/app/server
EnvironmentFile=/etc/neutype-meeting-transcription.env
ExecStart=/opt/neutype/meeting-transcription/.venv/bin/uvicorn meeting_transcription.app:create_app --factory --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
TimeoutStopSec=30

# 当前版本使用 in-process worker + SQLite，保持单进程。
# 不要在这里加 uvicorn --workers N。

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/neutype/meeting-transcription/data /opt/neutype/meeting-transcription/artifacts /opt/neutype/meeting-transcription/logs

[Install]
WantedBy=multi-user.target
EOF
```

启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable neutype-meeting-transcription
sudo systemctl start neutype-meeting-transcription
```

查看状态：

```bash
sudo systemctl status neutype-meeting-transcription --no-pager
sudo journalctl -u neutype-meeting-transcription -f
```

本机健康检查：

```bash
curl -fsS http://127.0.0.1:8000/healthz
```

预期：

```json
{"status":"ok"}
```

---

## 8. Nginx 反向代理

生产必须通过 HTTPS 暴露给客户端。

示例域名：

```text
meeting-transcription.example.com
```

仓库已提供可复制模板：

```bash
deploy/meeting-transcription/nginx.conf
```

Nginx 配置：

```nginx
server {
    listen 80;
    server_name meeting-transcription.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name meeting-transcription.example.com;

    ssl_certificate /etc/letsencrypt/live/meeting-transcription.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meeting-transcription.example.com/privkey.pem;

    # 会议音频可能较大，必须显式放大上传限制。
    client_max_body_size 2048m;
    client_body_timeout 1800s;
    proxy_read_timeout 1800s;
    proxy_send_timeout 1800s;

    location /healthz {
        proxy_pass http://127.0.0.1:8000/healthz;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /api/meeting-transcription/ {
        proxy_pass http://127.0.0.1:8000/api/meeting-transcription/;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

启用：

```bash
sudo nginx -t
sudo systemctl reload nginx
```

TLS 证书可用 certbot：

```bash
sudo certbot --nginx -d meeting-transcription.example.com
```

外部健康检查：

```bash
curl -fsS https://meeting-transcription.example.com/healthz
```

---

## 9. 客户端配置

macOS 客户端的 Meeting ASR Base URL 应填写服务根地址：

```text
https://meeting-transcription.example.com
```

不要填写：

```text
https://meeting-transcription.example.com/api/meeting-transcription/sessions
```

也不要把客户端直接指向 Gradio URL。原因：

- macOS 客户端调用的是 `/api/meeting-transcription/...` session API。
- Gradio URL 只供服务端 worker 调用。

---

## 10. 验收测试

### 10.1 服务健康

```bash
curl -fsS https://meeting-transcription.example.com/healthz
```

### 10.2 OpenAPI

```bash
curl -fsS https://meeting-transcription.example.com/openapi.json | head
```

### 10.3 创建 session smoke test

```bash
curl -i -X POST https://meeting-transcription.example.com/api/meeting-transcription/sessions \
  -H 'Content-Type: application/json' \
  -d '{
    "client_session_token": "prod-smoke-001",
    "source": "smoke",
    "chunk_duration_ms": 300000,
    "chunk_overlap_ms": 0,
    "audio_format": "wav",
    "sample_rate_hz": 16000,
    "channel_count": 1
  }'
```

预期：

- HTTP `201 Created` 或幂等复用时 `200 OK`
- body 包含：
  - `request_id`
  - `data.session_id`
  - `data.status`
  - `error: null`

### 10.4 完整链路验收

用 macOS 测试包执行：

1. 设置 Meeting ASR Base URL 为生产域名。
2. 录制一段 30 秒以上音频。
3. 停止录制。
4. 观察 UI：
   - chunk 上传成功。
   - status 从 processing 进入 completed。
   - transcript segment 时间线正确。
5. 查看服务端日志：

```bash
sudo journalctl -u neutype-meeting-transcription -n 200 --no-pager
```

---

## 11. 运维检查

### 11.1 进程

```bash
systemctl is-active neutype-meeting-transcription
pgrep -af 'uvicorn meeting_transcription.app:create_app'
```

预期只有一个 uvicorn 主进程。

### 11.2 数据库大小

```bash
sudo du -h /opt/neutype/meeting-transcription/data/meeting_transcription.db
```

### 11.3 Artifact 大小

```bash
sudo du -sh /opt/neutype/meeting-transcription/artifacts
```

### 11.4 最近错误日志

```bash
sudo journalctl -u neutype-meeting-transcription --since '1 hour ago' -p warning --no-pager
```

### 11.5 Gradio 后端可达性

```bash
curl -I https://546463aae3e7327f37.gradio.live/
```

如果 Gradio URL 变更，更新：

```bash
sudoedit /etc/neutype-meeting-transcription.env
sudo systemctl restart neutype-meeting-transcription
```

---

## 12. 升级流程

标准升级：

```bash
cd /opt/neutype/meeting-transcription/app
sudo -u neutype git fetch --all
sudo -u neutype git checkout <release-tag-or-commit>

cd /opt/neutype/meeting-transcription/app/server
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install -r requirements.txt

sudo cp /opt/neutype/meeting-transcription/data/meeting_transcription.db \
  /opt/neutype/meeting-transcription/data/meeting_transcription.db.$(date +%Y%m%d%H%M%S).bak

sudo -u neutype env $(cat /etc/neutype-meeting-transcription.env | xargs) \
  /opt/neutype/meeting-transcription/.venv/bin/python -m alembic upgrade head

sudo systemctl restart neutype-meeting-transcription
curl -fsS http://127.0.0.1:8000/healthz
```

升级后观察：

```bash
sudo journalctl -u neutype-meeting-transcription -f
```

---

## 13. 回滚流程

如果升级后出现生产故障：

```bash
cd /opt/neutype/meeting-transcription/app
sudo -u neutype git checkout <previous-good-commit>

sudo systemctl stop neutype-meeting-transcription

# 如本次升级执行过不可逆 schema migration，先评估 migration 是否兼容。
# SQLite 文件可用升级前备份恢复：
sudo cp /opt/neutype/meeting-transcription/data/meeting_transcription.db.<backup_timestamp>.bak \
  /opt/neutype/meeting-transcription/data/meeting_transcription.db
sudo chown neutype:neutype /opt/neutype/meeting-transcription/data/meeting_transcription.db

sudo systemctl start neutype-meeting-transcription
curl -fsS http://127.0.0.1:8000/healthz
```

---

## 14. 安全注意事项

当前服务端路由没有内建鉴权中间件。生产暴露公网前必须至少满足以下之一：

1. 放在受控内网/VPN 后面。
2. 在 Nginx / API Gateway 层增加鉴权。
3. 只允许客户端所在网络段访问。

Nginx IP allowlist 示例：

```nginx
location /api/meeting-transcription/ {
    allow 203.0.113.0/24;
    deny all;

    proxy_pass http://127.0.0.1:8000/api/meeting-transcription/;
    proxy_request_buffering off;
}
```

如果需要公网 API Key 鉴权，应新增应用层校验，而不是只依赖隐藏 URL。

隐私要求：

- 上传音频和转写结果属于敏感数据。
- artifact 目录和数据库必须限制系统权限。
- 日志中避免输出完整 transcript 或音频内容。
- 备份数据应加密。

---

## 15. 当前版本已知限制

1. 当前推荐单实例部署。
2. 当前推荐 SQLite 持久化，适合单机部署。
3. 当前 worker 是 in-process thread，不是独立队列服务。
4. 没有内建 artifact 生命周期清理。
5. 没有内建公网鉴权。
6. Gradio 后端 URL 可能临时变化，需要运维更新环境变量并重启服务。

这些限制不影响单机生产验证，但上线到多人长期使用前，应优先补：

- API 鉴权
- artifact 清理策略
- worker 独立进程化
- Postgres / 任务队列
- 结构化日志和指标监控
