# NeuType

NeuType is a macOS app for fast voice-to-text on Apple Silicon Macs. It supports live dictation, file transcription, and a meeting transcription workflow backed by a FastAPI server.

<p align="center">
<img src="docs/image.png" width="400" /> <img src="docs/image_indicator.png" width="400" />
</p>

## Features

- 🎙️ Real-time audio recording and transcription
- ☁️ Cloud ASR via Groq (`whisper-large-v3`)
- 🧠 Meeting transcription pipeline with chunk upload, server-side processing, and transcript polling
- ⌨️ Start recording with a single modifier key in Multi Button mode
- 📁 Drag and drop audio files for queued transcription
- 🎤 Microphone selection for built-in, external, Bluetooth, and iPhone Continuity mics
- ✨ Optional transcript cleanup with LLM post-processing

## Installation

Download the latest macOS build from the [GitHub Releases page](https://github.com/chenhaoran0612/neuType/releases).

## Requirements

- macOS on Apple Silicon, M1/M2/M3/M4 and newer

## Local build

```bash
git clone git@github.com:chenhaoran0612/neuType.git
cd NeuType
git submodule update --init --recursive
brew install cmake libomp rust ruby
gem install xcpretty
./run.sh build
```

If the local build behaves differently from your machine, check `.github/workflows/build.yml`. That is the CI path we use to build the app on GitHub Actions.

## Meeting transcription server

NeuType includes a FastAPI service under `server/` for meeting transcription. The macOS client uploads 5-minute WAV chunks during recording, uploads the full recording as fallback, then polls the server until the transcript is complete.

### Runtime model

- `POST /api/meeting-transcription/sessions` creates or resumes a session by `client_session_token`
- `PUT /api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}` stores idempotent live chunk uploads
- `PUT /api/meeting-transcription/sessions/{session_id}/full-audio` stores the full recording as fallback
- `POST /api/meeting-transcription/sessions/{session_id}/finalize` seals the upload and makes work visible to the worker
- `GET /api/meeting-transcription/sessions/{session_id}` returns status, transcript segments, and error details
- `GET /healthz` returns the server health check

Current production shape is **one uvicorn process with one in-process worker thread**. Do not run `uvicorn --workers N` yet. Multiple FastAPI worker processes would also start multiple background workers, which is not what this version is built for.

### Local server setup

Use Python 3.12+.

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Environment variables:

```bash
export MEETING_TRANSCRIPTION_DATABASE_URL="sqlite+pysqlite:///./meeting_transcription.db"
export MEETING_TRANSCRIPTION_STORAGE_ROOT="./artifacts"
export MEETING_TRANSCRIPTION_GRADIO_BASE_URL="https://546463aae3e7327f37.gradio.live/"
export MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS=4096
export MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE=0.0
export MEETING_TRANSCRIPTION_GRADIO_TOP_P=1.0
export MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE=false
export MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO=""
export MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS=1.0
```

Run migrations and start the API:

```bash
cd server
source .venv/bin/activate
python -m alembic upgrade head
uvicorn meeting_transcription.app:create_app --factory --host 127.0.0.1 --port 8000
```

Quick checks:

```bash
curl http://127.0.0.1:8000/healthz
curl http://127.0.0.1:8000/openapi.json
```

Focused regression tests:

```bash
cd server
pytest tests/test_session_routes.py tests/test_worker_processing.py tests/test_anchor_audio.py -q
```

## 服务端部署文档

这一节是根 README 内的服务端部署说明。你不需要再去翻别的文件才能把服务先跑起来。更完整的模板和运维说明仍然放在 `server/PRODUCTION_DEPLOYMENT.md`、`server/README.md`、`deploy/meeting-transcription/README.md`。

### 1. 适用场景

NeuType 会议转写服务端负责：

- 接收 macOS 客户端上传的实时音频 chunk
- 保存 full audio fallback
- 调用 Gradio ASR 后端处理音频
- 生成 transcript segments 并返回给客户端轮询

当前版本推荐 **单机部署**：

- 1 个 FastAPI 进程
- 1 个 in-process worker thread
- SQLite 持久化
- 本地磁盘保存 artifacts

这套架构适合先上线、先验证。够直接，也方便排错。

### 2. 服务器要求

推荐环境：

- Ubuntu 22.04 LTS 或 24.04 LTS
- Python 3.12+
- systemd
- Nginx
- 持久化磁盘

磁盘会保存这些东西：

- live chunk WAV
- full audio fallback
- speaker anchor WAV
- prefix WAV
- SQLite 数据库文件

建议至少预留 `50GB` artifact 空间，后续按会议量扩容。

### 3. 推荐目录结构

```bash
/opt/neutype/meeting-transcription
├── app/
├── .venv/
├── data/
│   └── meeting_transcription.db
├── artifacts/
└── logs/
```

创建系统用户和目录：

```bash
sudo useradd --system --home /opt/neutype --shell /usr/sbin/nologin neutype
sudo mkdir -p /opt/neutype/meeting-transcription/{app,data,artifacts,logs}
sudo chown -R neutype:neutype /opt/neutype
```

### 4. 安装代码和依赖

```bash
sudo -u neutype git clone <YOUR_REPO_URL> /opt/neutype/meeting-transcription/app
cd /opt/neutype/meeting-transcription/app/server

sudo -u neutype python3.12 -m venv /opt/neutype/meeting-transcription/.venv
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install --upgrade pip
sudo -u neutype /opt/neutype/meeting-transcription/.venv/bin/pip install -r requirements.txt
```

### 5. 生产环境变量

把下面内容保存到 `/etc/neutype-meeting-transcription.env`：

```bash
MEETING_TRANSCRIPTION_DATABASE_URL=sqlite+pysqlite:////opt/neutype/meeting-transcription/data/meeting_transcription.db
MEETING_TRANSCRIPTION_STORAGE_ROOT=/opt/neutype/meeting-transcription/artifacts

MEETING_TRANSCRIPTION_GRADIO_BASE_URL=https://546463aae3e7327f37.gradio.live/
MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS=4096
MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE=0.0
MEETING_TRANSCRIPTION_GRADIO_TOP_P=1.0
MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE=false
MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO=

MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS=1.0
```

然后设置权限：

```bash
sudo chown root:neutype /etc/neutype-meeting-transcription.env
sudo chmod 640 /etc/neutype-meeting-transcription.env
```

重点就三个：

- `MEETING_TRANSCRIPTION_DATABASE_URL` 指向持久化 SQLite 文件
- `MEETING_TRANSCRIPTION_STORAGE_ROOT` 指向持久化 artifact 目录
- `MEETING_TRANSCRIPTION_GRADIO_BASE_URL` 指向服务端用的 ASR backend

### 6. 数据库迁移

首次部署和每次升级前，都先跑 Alembic：

```bash
cd /opt/neutype/meeting-transcription/app/server
sudo -u neutype env $(cat /etc/neutype-meeting-transcription.env | xargs) \
  /opt/neutype/meeting-transcription/.venv/bin/python -m alembic upgrade head
```

查看当前 migration revision：

```bash
cd /opt/neutype/meeting-transcription/app/server
sudo -u neutype env $(cat /etc/neutype-meeting-transcription.env | xargs) \
  /opt/neutype/meeting-transcription/.venv/bin/python -m alembic current
```

### 7. systemd 部署

仓库已经带了模板文件：

- `deploy/meeting-transcription/neutype-meeting-transcription.env.example`
- `deploy/meeting-transcription/neutype-meeting-transcription.service`
- `deploy/meeting-transcription/nginx.conf`
- `deploy/meeting-transcription/install.sh`

最省事的方式：

```bash
sudo deploy/meeting-transcription/install.sh
```

如果你想手动建 service，用这个：

```ini
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
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/neutype/meeting-transcription/data /opt/neutype/meeting-transcription/artifacts /opt/neutype/meeting-transcription/logs

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable neutype-meeting-transcription
sudo systemctl start neutype-meeting-transcription
sudo systemctl status neutype-meeting-transcription --no-pager
sudo journalctl -u neutype-meeting-transcription -f
```

### 8. Nginx 和 HTTPS

生产环境必须给 macOS 客户端暴露 HTTPS。仓库自带模板 `deploy/meeting-transcription/nginx.conf`，核心配置如下：

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

启用和校验：

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d meeting-transcription.example.com
```

### 9. 客户端配置

macOS 客户端里的 Meeting ASR Base URL 要填服务根地址：

```text
https://meeting-transcription.example.com
```

不要填成下面这种：

```text
https://meeting-transcription.example.com/api/meeting-transcription/sessions
```

也不要把客户端直接指向 Gradio URL。客户端走的是 FastAPI session API，不是 Gradio 的队列接口。

### 10. 验收和运维

健康检查：

```bash
curl -fsS http://127.0.0.1:8000/healthz
curl -fsS https://meeting-transcription.example.com/healthz
```

OpenAPI：

```bash
curl -fsS https://meeting-transcription.example.com/openapi.json | head
```

创建 session smoke test：

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

常用运维检查：

```bash
systemctl is-active neutype-meeting-transcription
pgrep -af 'uvicorn meeting_transcription.app:create_app'
sudo du -h /opt/neutype/meeting-transcription/data/meeting_transcription.db
sudo du -sh /opt/neutype/meeting-transcription/artifacts
sudo journalctl -u neutype-meeting-transcription --since '1 hour ago' -p warning --no-pager
curl -I https://546463aae3e7327f37.gradio.live/
```

### 11. 升级和回滚

升级：

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

回滚：

```bash
cd /opt/neutype/meeting-transcription/app
sudo -u neutype git checkout <previous-good-commit>

sudo systemctl stop neutype-meeting-transcription
sudo cp /opt/neutype/meeting-transcription/data/meeting_transcription.db.<backup_timestamp>.bak \
  /opt/neutype/meeting-transcription/data/meeting_transcription.db
sudo chown neutype:neutype /opt/neutype/meeting-transcription/data/meeting_transcription.db
sudo systemctl start neutype-meeting-transcription
curl -fsS http://127.0.0.1:8000/healthz
```

### 12. 安全和已知限制

当前服务端没有内建鉴权中间件。对公网开放前，至少做一件事：

1. 放到内网或 VPN 后面
2. 在 Nginx / API Gateway 层加鉴权
3. 做 IP allowlist

还要知道这些限制：

- 当前推荐单实例部署
- 当前推荐 SQLite，适合单机
- worker 还是 in-process thread
- 没有自动 artifact 清理
- Gradio backend URL 变更后需要更新环境变量并重启

如果你要把它长期跑在多人生产环境里，优先补这几个：

- API 鉴权
- artifact 生命周期清理
- 独立 worker 进程
- Postgres 和任务队列
- 结构化日志与指标监控

## Support

If you hit a bug or have questions:

1. Check existing issues first
2. Open a new issue with reproduction details
3. Include system information, logs, and the exact command or request that failed

## Contributing

Pull requests and issues are welcome.

## License

NeuType is licensed under the MIT License. See [LICENSE](LICENSE) for details.
