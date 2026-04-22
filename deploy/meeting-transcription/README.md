# NeuType Meeting Transcription 部署模板

本目录提供生产部署可直接复制的模板文件。

## 文件

- `neutype-meeting-transcription.env.example`
  - systemd `EnvironmentFile` 示例。
- `neutype-meeting-transcription.service`
  - systemd service 模板。
- `nginx.conf`
  - Nginx HTTPS 反向代理模板。
- `install.sh`
  - 把 env / systemd / Nginx 模板安装到推荐位置的辅助脚本。

## 推荐安装位置

```bash
sudo cp deploy/meeting-transcription/neutype-meeting-transcription.env.example /etc/neutype-meeting-transcription.env
sudo cp deploy/meeting-transcription/neutype-meeting-transcription.service /etc/systemd/system/neutype-meeting-transcription.service
sudo cp deploy/meeting-transcription/nginx.conf /etc/nginx/sites-available/neutype-meeting-transcription.conf
sudo ln -sf /etc/nginx/sites-available/neutype-meeting-transcription.conf /etc/nginx/sites-enabled/neutype-meeting-transcription.conf
```

或使用辅助脚本：

```bash
sudo deploy/meeting-transcription/install.sh
```

如机器尚未安装 Nginx：

```bash
sudo deploy/meeting-transcription/install.sh --skip-nginx
```

部署前必须替换：

- `meeting-transcription.example.com`
- `<YOUR_GRADIO_URL_IF_DIFFERENT>`
- 证书路径
- 代码仓库路径如有调整

完整部署步骤见：

- `server/PRODUCTION_DEPLOYMENT.md`
