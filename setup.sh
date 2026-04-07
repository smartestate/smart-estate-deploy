#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo ./setup.sh"
  exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
  echo "This script currently supports Debian/Ubuntu only."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="/opt/smartestate"
ENV_FILE="${DEPLOY_ROOT}/.env"

echo "== Smart Estate VPS Setup =="
echo "This will configure Docker, Nginx, Certbot, firewall, and app deployment."

read -r -p "Backend Git URL [https://github.com/smartestate/smart-estate-backend.git]: " BACKEND_REPO
BACKEND_REPO=${BACKEND_REPO:-https://github.com/smartestate/smart-estate-backend.git}

read -r -p "Dashboard Git URL [https://github.com/smartestate/smart-estate-dashboard.git]: " DASHBOARD_REPO
DASHBOARD_REPO=${DASHBOARD_REPO:-https://github.com/smartestate/smart-estate-dashboard.git}

read -r -p "Use custom domains? (y/N): " USE_DOMAINS
USE_DOMAINS=${USE_DOMAINS:-N}

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  read -r -p "API domain [api.smartestate.me]: " API_DOMAIN
  API_DOMAIN=${API_DOMAIN:-api.smartestate.me}

  read -r -p "App domain [app.smartestate.me]: " APP_DOMAIN
  APP_DOMAIN=${APP_DOMAIN:-app.smartestate.me}
else
  VPS_IP="$(hostname -I | awk '{print $1}')"
  API_DOMAIN="${VPS_IP}"
  APP_DOMAIN="${VPS_IP}"
fi

read -r -p "OpenAI API key (optional, leave blank to skip): " OPENAI_API_KEY
read -r -p "OpenRouteService API key (optional, leave blank to skip): " ORS_API_KEY
read -r -p "Sentry DSN (optional, leave blank to skip): " SENTRY_DSN
read -r -p "DB user [smartestate]: " DB_USER
DB_USER=${DB_USER:-smartestate}
read -r -p "DB name [smartestate]: " DB_NAME
DB_NAME=${DB_NAME:-smartestate}

JWT_SECRET_KEY="$(openssl rand -hex 32)"
DB_PASSWORD="$(openssl rand -hex 16)"

echo "Generated JWT_SECRET_KEY and DB_PASSWORD."

echo "Updating packages..."
apt update && apt upgrade -y

echo "Installing dependencies..."
apt install -y docker.io docker-compose docker-compose-plugin nginx certbot python3-certbot-nginx ufw git openssl curl

echo "Configuring firewall..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

echo "Enabling Docker..."
systemctl enable docker
systemctl start docker

mkdir -p "${DEPLOY_ROOT}" "${DEPLOY_ROOT}/uploads" "${DEPLOY_ROOT}/saved_models"

clone_or_pull() {
  local repo_url="$1"
  local target_dir="$2"

  if [[ -d "${target_dir}/.git" ]]; then
    git -C "${target_dir}" fetch --all
    git -C "${target_dir}" checkout main || true
    git -C "${target_dir}" pull --ff-only origin main || true
  else
    git clone "${repo_url}" "${target_dir}"
  fi
}

echo "Cloning application repositories..."
clone_or_pull "${BACKEND_REPO}" "${DEPLOY_ROOT}/smart-estate-backend"
clone_or_pull "${DASHBOARD_REPO}" "${DEPLOY_ROOT}/smart-estate-dashboard"

if [[ ! -f "${DEPLOY_ROOT}/smart-estate-backend/Dockerfile" ]]; then
  echo "Error: backend Dockerfile missing in ${DEPLOY_ROOT}/smart-estate-backend"
  exit 1
fi

if [[ ! -f "${DEPLOY_ROOT}/smart-estate-dashboard/Dockerfile" ]]; then
  echo "Error: dashboard Dockerfile missing in ${DEPLOY_ROOT}/smart-estate-dashboard"
  exit 1
fi

CORS_ORIGINS="https://${APP_DOMAIN},https://${API_DOMAIN}"
VITE_API_URL="https://${API_DOMAIN}"
if [[ ! "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  CORS_ORIGINS="http://${APP_DOMAIN}:3000,http://${API_DOMAIN}:3000"
  VITE_API_URL="http://${API_DOMAIN}:8000"
fi

cat > "${ENV_FILE}" <<EOF
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=postgres
DB_PORT=5432
DB_NAME=${DB_NAME}

JWT_SECRET_KEY=${JWT_SECRET_KEY}
JWT_ALGORITHM=HS256
JWT_EXPIRY_MINUTES=1440

OPENAI_API_KEY=${OPENAI_API_KEY}
ORS_API_KEY=${ORS_API_KEY}

CORS_ORIGINS=${CORS_ORIGINS}
SENTRY_DSN=${SENTRY_DSN}
ENVIRONMENT=production
UPLOAD_DIR=/app/uploads
VITE_API_URL=${VITE_API_URL}
EOF
chmod 600 "${ENV_FILE}"

cp "${SCRIPT_DIR}/docker-compose.yml" "${DEPLOY_ROOT}/docker-compose.yml"

cat > /etc/nginx/sites-available/smartestate <<EOF
server {
    server_name ${API_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }

    client_max_body_size 20M;
}

server {
    server_name ${APP_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/smartestate /etc/nginx/sites-enabled/smartestate
nginx -t && systemctl reload nginx

echo "Starting stack with Docker Compose..."
cd "${DEPLOY_ROOT}"
docker compose --env-file .env up -d --build

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  echo "Run SSL provisioning after DNS propagation:"
  echo "  certbot --nginx -d ${API_DOMAIN} -d ${APP_DOMAIN}"
  echo "Then verify DNS:"
  echo "  dig ${API_DOMAIN} +short"
else
  echo "Custom domains not configured. Use these URLs:"
  echo "  API: http://${API_DOMAIN}:8000"
  echo "  Dashboard: http://${APP_DOMAIN}:3000"
fi

echo "Done."
