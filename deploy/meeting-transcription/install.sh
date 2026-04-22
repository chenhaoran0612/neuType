#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVICE_NAME="neutype-meeting-transcription"
ENV_SOURCE="${SCRIPT_DIR}/neutype-meeting-transcription.env.example"
SERVICE_SOURCE="${SCRIPT_DIR}/neutype-meeting-transcription.service"
NGINX_SOURCE="${SCRIPT_DIR}/nginx.conf"

ENV_TARGET="/etc/${SERVICE_NAME}.env"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_AVAILABLE="/etc/nginx/sites-available/${SERVICE_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"

APP_ROOT="/opt/neutype/meeting-transcription"
APP_USER="neutype"
APP_GROUP="neutype"

usage() {
  cat <<EOF
Usage:
  sudo $0 [--force] [--skip-nginx]

Installs NeuType Meeting Transcription deployment templates:
  - ${ENV_TARGET}
  - ${SERVICE_TARGET}
  - ${NGINX_AVAILABLE}

Options:
  --force       Overwrite existing target files.
  --skip-nginx  Do not install or enable the Nginx template.

After running:
  1. Edit ${ENV_TARGET}
  2. Edit ${NGINX_AVAILABLE} and replace meeting-transcription.example.com
  3. Install TLS certificates
  4. Run migrations
  5. Start the service
EOF
}

FORCE=0
SKIP_NGINX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --skip-nginx)
      SKIP_NGINX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "This installer must run as root. Use sudo." >&2
  exit 1
fi

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "Missing template file: ${path}" >&2
    exit 1
  fi
}

install_file() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"

  if [[ -e "${target}" && "${FORCE}" -ne 1 ]]; then
    echo "Skip existing file: ${target}  (use --force to overwrite)"
    return
  fi

  install -D -m "${mode}" -o "${owner}" -g "${group}" "${source}" "${target}"
  echo "Installed: ${target}"
}

require_file "${ENV_SOURCE}"
require_file "${SERVICE_SOURCE}"
require_file "${NGINX_SOURCE}"

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --home /opt/neutype --shell /usr/sbin/nologin "${APP_USER}"
  echo "Created system user: ${APP_USER}"
fi

mkdir -p "${APP_ROOT}/"{app,data,artifacts,logs}
chown -R "${APP_USER}:${APP_GROUP}" /opt/neutype
echo "Prepared app directories under ${APP_ROOT}"

install_file "${ENV_SOURCE}" "${ENV_TARGET}" 0640 root "${APP_GROUP}"
install_file "${SERVICE_SOURCE}" "${SERVICE_TARGET}" 0644 root root

systemctl daemon-reload
echo "Reloaded systemd units"

if [[ "${SKIP_NGINX}" -ne 1 ]]; then
  if [[ ! -d /etc/nginx ]]; then
    echo "Nginx directory /etc/nginx not found. Install nginx first or rerun with --skip-nginx." >&2
    exit 1
  fi

  install_file "${NGINX_SOURCE}" "${NGINX_AVAILABLE}" 0644 root root
  mkdir -p /etc/nginx/sites-enabled
  ln -sfn "${NGINX_AVAILABLE}" "${NGINX_ENABLED}"
  echo "Enabled Nginx site: ${NGINX_ENABLED}"

  if nginx -t; then
    echo "Nginx config syntax is valid"
  else
    echo "Nginx config test failed. Edit ${NGINX_AVAILABLE} before reloading nginx." >&2
    exit 1
  fi
fi

cat <<EOF

Install templates completed.

Next steps:
  1. Edit environment:
     sudoedit ${ENV_TARGET}

  2. Edit Nginx domain/cert paths:
     sudoedit ${NGINX_AVAILABLE}

  3. Install Python dependencies in:
     ${APP_ROOT}/.venv

  4. Run Alembic migrations from app/server.

  5. Start service:
     sudo systemctl enable --now ${SERVICE_NAME}

  6. Check health:
     curl -fsS http://127.0.0.1:8000/healthz

Full guide:
  server/PRODUCTION_DEPLOYMENT.md
EOF
