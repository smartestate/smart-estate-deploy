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
SAMPLE_FILE="${SCRIPT_DIR}/env.sample"

get_env_value() {
  local key="$1"
  local value=""

  if [[ -f "${ENV_FILE}" ]]; then
    value="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true)"
  fi

  printf '%s' "${value}"
}

get_sample_value() {
  local key="$1"
  local value=""

  if [[ -f "${SAMPLE_FILE}" ]]; then
    value="$(grep -E "^${key}=" "${SAMPLE_FILE}" | tail -n 1 | cut -d= -f2- || true)"
  fi

  printf '%s' "${value}"
}

extract_host_from_url() {
  local url="$1"
  url="${url#*://}"
  url="${url%%/*}"
  url="${url%%:*}"
  printf '%s' "${url}"
}

resolve_ipv4() {
  local hostname="$1"
  getent ahostsv4 "${hostname}" 2>/dev/null | awk 'NR==1 { print $1 }'
}

prompt_default() {
  local prompt_text="$1"
  local default_value="$2"
  local response=""

  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " response
    printf '%s' "${response:-${default_value}}"
  else
    read -r -p "${prompt_text}: " response
    printf '%s' "${response}"
  fi
}

echo "== Smart Estate VPS Setup =="
cat <<'EOF'

  ____                      _      _____     _        _
 / ___| _ __ ___   __ _ _ __| |_   | ____|___| |_ __ _| |_ ___
 \___ \| '_ ` _ \ / _` | '__| __|  |  _| / __| __/ _` | __/ _ \
  ___) | | | | | | (_| | |  | |_   | |___\__ \ || (_| | ||  __/
 |____/|_| |_| |_|\__,_|_|   \__|  |_____|___/\__\__,_|\__\___|

                 Property maintenance, reimagined

EOF
echo "This setup will configure Docker, Nginx, Certbot, firewall, and app deployment."

read -r -p "GitHub username for private repos (leave blank for public repos): " GITHUB_USERNAME
if [[ -n "${GITHUB_USERNAME}" ]]; then
  read -r -s -p "GitHub PAT with repo read access: " GITHUB_PAT
  echo
fi

auth_repo_url() {
  local repo_url="$1"

  if [[ -z "${GITHUB_USERNAME}" || -z "${GITHUB_PAT}" ]]; then
    printf '%s' "${repo_url}"
    return
  fi

  printf '%s' "${repo_url/https:\/\/github.com/https://${GITHUB_USERNAME}:${GITHUB_PAT}@github.com}"
}

read -r -p "Backend Git URL [https://github.com/YOUR_ORG/smart-estate-backend.git]: " BACKEND_REPO
BACKEND_REPO=${BACKEND_REPO:-https://github.com/YOUR_ORG/smart-estate-backend.git}

read -r -p "Dashboard Git URL [https://github.com/YOUR_ORG/smart-estate-dashboard.git]: " DASHBOARD_REPO
DASHBOARD_REPO=${DASHBOARD_REPO:-https://github.com/YOUR_ORG/smart-estate-dashboard.git}

read -r -p "Use custom domains? (y/N): " USE_DOMAINS
USE_DOMAINS=${USE_DOMAINS:-N}

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  CERTBOT_EMAIL=""
  read -r -p "SSL certificate email (optional, leave blank to skip): " CERTBOT_EMAIL

  if [[ -n "${EXISTING_API_DOMAIN}" && -n "${EXISTING_APP_DOMAIN}" ]]; then
    API_DOMAIN="${EXISTING_API_DOMAIN}"
    APP_DOMAIN="${EXISTING_APP_DOMAIN}"
    echo "Keeping existing API_DOMAIN and APP_DOMAIN from ${ENV_FILE}."
  elif [[ -n "${EXISTING_VITE_API_URL}" && -n "${EXISTING_CORS_ORIGINS}" ]]; then
    API_DOMAIN="$(extract_host_from_url "${EXISTING_VITE_API_URL}")"
    APP_DOMAIN="$(printf '%s' "${EXISTING_CORS_ORIGINS}" | cut -d, -f1 | sed -E 's#^https?://##; s#/.*$##; s/:.*$##')"
    echo "Derived API_DOMAIN and APP_DOMAIN from existing deployment settings."
  else
    read -r -p "API domain [api.your-domain.com]: " API_DOMAIN
    API_DOMAIN=${API_DOMAIN:-api.your-domain.com}

    read -r -p "App domain [app.your-domain.com]: " APP_DOMAIN
    APP_DOMAIN=${APP_DOMAIN:-app.your-domain.com}
  fi
else
  VPS_IP="$(hostname -I | awk '{print $1}')"
  API_DOMAIN="${VPS_IP}"
  APP_DOMAIN="${VPS_IP}"
fi

EXISTING_DB_USER="$(get_env_value DB_USER)"
EXISTING_DB_PASSWORD="$(get_env_value DB_PASSWORD)"
EXISTING_DB_NAME="$(get_env_value DB_NAME)"
EXISTING_JWT_SECRET_KEY="$(get_env_value JWT_SECRET_KEY)"
EXISTING_OPENAI_API_KEY="$(get_env_value OPENAI_API_KEY)"
EXISTING_ORS_API_KEY="$(get_env_value ORS_API_KEY)"
EXISTING_SENTRY_DSN="$(get_env_value SENTRY_DSN)"
EXISTING_CORS_ORIGINS="$(get_env_value CORS_ORIGINS)"
EXISTING_VITE_API_URL="$(get_env_value VITE_API_URL)"
EXISTING_API_DOMAIN="$(get_env_value API_DOMAIN)"
EXISTING_APP_DOMAIN="$(get_env_value APP_DOMAIN)"
EXISTING_ENVIRONMENT="$(get_env_value ENVIRONMENT)"
EXISTING_UPLOAD_DIR="$(get_env_value UPLOAD_DIR)"

SAMPLE_DB_USER="$(get_sample_value DB_USER)"
SAMPLE_DB_NAME="$(get_sample_value DB_NAME)"
SAMPLE_CORS_ORIGINS="$(get_sample_value CORS_ORIGINS)"
SAMPLE_ENVIRONMENT="$(get_sample_value ENVIRONMENT)"
SAMPLE_UPLOAD_DIR="$(get_sample_value UPLOAD_DIR)"
SAMPLE_VITE_API_URL="$(get_sample_value VITE_API_URL)"

OPENAI_API_KEY="${EXISTING_OPENAI_API_KEY}"
if [[ -z "${OPENAI_API_KEY}" ]]; then
  read -r -p "OpenAI API key (optional, leave blank to skip): " OPENAI_API_KEY
fi

ORS_API_KEY="${EXISTING_ORS_API_KEY}"
if [[ -z "${ORS_API_KEY}" ]]; then
  read -r -p "OpenRouteService API key (optional, leave blank to skip): " ORS_API_KEY
fi

SENTRY_DSN="${EXISTING_SENTRY_DSN}"
if [[ -z "${SENTRY_DSN}" ]]; then
  read -r -p "Sentry DSN (optional, leave blank to skip): " SENTRY_DSN
fi

if [[ -n "${EXISTING_DB_USER}" ]]; then
  DB_USER="${EXISTING_DB_USER}"
  echo "Keeping existing DB_USER from ${ENV_FILE}."
else
  DB_USER="$(prompt_default "DB user" "${SAMPLE_DB_USER:-smartestate}")"
fi

if [[ -n "${EXISTING_DB_NAME}" ]]; then
  DB_NAME="${EXISTING_DB_NAME}"
  echo "Keeping existing DB_NAME from ${ENV_FILE}."
else
  DB_NAME="$(prompt_default "DB name" "${SAMPLE_DB_NAME:-smartestate}")"
fi

if [[ -n "${EXISTING_JWT_SECRET_KEY}" ]]; then
  JWT_SECRET_KEY="${EXISTING_JWT_SECRET_KEY}"
  echo "Keeping existing JWT_SECRET_KEY from ${ENV_FILE}."
else
  JWT_SECRET_KEY="$(openssl rand -hex 32)"
  echo "Generated JWT_SECRET_KEY."
fi

if [[ -n "${EXISTING_DB_PASSWORD}" ]]; then
  DB_PASSWORD="${EXISTING_DB_PASSWORD}"
  echo "Keeping existing DB_PASSWORD from ${ENV_FILE}."
else
  DB_PASSWORD="$(openssl rand -hex 16)"
  echo "Generated DB_PASSWORD."
fi

echo "Updating packages..."
apt update && apt upgrade -y

echo "Installing dependencies..."
apt install -y docker.io nginx certbot python3-certbot-nginx ufw git openssl curl

# Compose package names vary by distro/repo. Try common options.
if ! apt install -y docker-compose-plugin; then
  apt install -y docker-compose-v2 || apt install -y docker-compose || true
fi

echo "Configuring firewall..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

echo "Enabling Docker..."
systemctl enable docker
systemctl start docker

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "Error: Docker Compose is not installed."
  echo "Install one of: docker-compose-plugin, docker-compose-v2, or docker-compose"
  exit 1
fi

mkdir -p "${DEPLOY_ROOT}" "${DEPLOY_ROOT}/uploads" "${DEPLOY_ROOT}/saved_models"

clone_or_pull() {
  local repo_url="$1"
  local target_dir="$2"
  local auth_url
  auth_url="$(auth_repo_url "${repo_url}")"

  if [[ -d "${target_dir}/.git" ]]; then
    local original_remote_url
    original_remote_url="$(git -C "${target_dir}" remote get-url origin)"
    if [[ "${auth_url}" != "${original_remote_url}" ]]; then
      git -C "${target_dir}" remote set-url origin "${auth_url}"
    fi
    trap "git -C '${target_dir}' remote set-url origin '${original_remote_url}' >/dev/null 2>&1 || true" RETURN
    git -C "${target_dir}" fetch --all
    git -C "${target_dir}" checkout main || true
    git -C "${target_dir}" pull --ff-only origin main || true
  else
    git clone "${auth_url}" "${target_dir}"
    if [[ -n "${GITHUB_USERNAME}" && -n "${GITHUB_PAT}" ]]; then
      git -C "${target_dir}" remote set-url origin "${repo_url}"
    fi
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

if [[ -n "${EXISTING_CORS_ORIGINS}" ]]; then
  CORS_ORIGINS="${EXISTING_CORS_ORIGINS}"
else
  CORS_ORIGINS="${SAMPLE_CORS_ORIGINS:-https://${APP_DOMAIN},https://${API_DOMAIN}}"
  if [[ ! "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
    CORS_ORIGINS="http://${APP_DOMAIN}:3000,http://${API_DOMAIN}:3000"
  fi
fi

if [[ -n "${EXISTING_VITE_API_URL}" ]]; then
  VITE_API_URL="${EXISTING_VITE_API_URL}"
else
  VITE_API_URL="${SAMPLE_VITE_API_URL:-https://${API_DOMAIN}}"
  if [[ ! "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
    VITE_API_URL="http://${API_DOMAIN}:8000"
  fi
fi

ENVIRONMENT="${EXISTING_ENVIRONMENT:-${SAMPLE_ENVIRONMENT:-production}}"
UPLOAD_DIR="${EXISTING_UPLOAD_DIR:-${SAMPLE_UPLOAD_DIR:-/app/uploads}}"

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
ENVIRONMENT=${ENVIRONMENT}
UPLOAD_DIR=${UPLOAD_DIR}
VITE_API_URL=${VITE_API_URL}
API_DOMAIN=${API_DOMAIN}
APP_DOMAIN=${APP_DOMAIN}
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
"${COMPOSE_CMD[@]}" --env-file .env up -d --build

echo "Running post-deploy smoke checks..."
if curl -fsS "http://127.0.0.1:8000/health" >/dev/null; then
  echo "  [ok] Backend is healthy on localhost:8000"
else
  echo "  [warn] Backend health check failed on localhost:8000"
  echo "         Check logs: ${COMPOSE_CMD[*]} -f ${DEPLOY_ROOT}/docker-compose.yml logs --tail=100 backend"
fi

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  CURRENT_IP="$(hostname -I | awk '{print $1}')"
  API_DNS_IP="$(resolve_ipv4 "${API_DOMAIN}")"
  APP_DNS_IP="$(resolve_ipv4 "${APP_DOMAIN}")"

  if [[ -n "${API_DNS_IP}" && -n "${APP_DNS_IP}" && "${API_DNS_IP}" == "${CURRENT_IP}" && "${APP_DNS_IP}" == "${CURRENT_IP}" ]]; then
    CERTBOT_CMD=(certbot --nginx -d "${API_DOMAIN}" -d "${APP_DOMAIN}" --non-interactive --agree-tos)
    if [[ -n "${CERTBOT_EMAIL}" ]]; then
      CERTBOT_CMD+=(--email "${CERTBOT_EMAIL}")
    else
      CERTBOT_CMD+=(--register-unsafely-without-email)
    fi

    echo "Running SSL provisioning now that DNS points to this VPS..."
    "${CERTBOT_CMD[@]}"

    if curl -fsS "https://${API_DOMAIN}/health" >/dev/null; then
      echo "  [ok] API HTTPS health check passed"
    else
      echo "  [warn] API HTTPS health check failed after certificate provisioning"
    fi
  else
    echo "  [warn] DNS is not yet pointing at this VPS for both domains"
    echo "         API resolves to: ${API_DNS_IP:-<unresolved>}"
    echo "         App resolves to: ${APP_DNS_IP:-<unresolved>}"
    echo "         Current VPS IP: ${CURRENT_IP}"
    echo "         SSL provisioning was skipped for now. Re-run setup after DNS propagates."
  fi

  CORS_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS "https://${API_DOMAIN}/auth/login" -H "Origin: https://${APP_DOMAIN}" -H "Access-Control-Request-Method: POST" || true)"
  if printf '%s' "${CORS_HEADERS}" | grep -iq "access-control-allow-origin: https://${APP_DOMAIN}"; then
    echo "  [ok] CORS preflight looks correct for app domain"
  else
    echo "  [warn] CORS preflight did not return expected allow-origin"
    echo "         Expected origin: https://${APP_DOMAIN}"
    echo "         Current CORS_ORIGINS in ${ENV_FILE}: $(grep -E '^CORS_ORIGINS=' "${ENV_FILE}" | cut -d= -f2-)"
  fi
else
  CORS_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS "http://${API_DOMAIN}:8000/auth/login" -H "Origin: http://${APP_DOMAIN}:3000" -H "Access-Control-Request-Method: POST" || true)"
  if printf '%s' "${CORS_HEADERS}" | grep -iq "access-control-allow-origin: http://${APP_DOMAIN}:3000"; then
    echo "  [ok] CORS preflight looks correct for local IP mode"
  else
    echo "  [warn] CORS preflight did not return expected allow-origin for local IP mode"
  fi

  echo "Custom domains not configured. Use these URLs:"
  echo "  API: http://${API_DOMAIN}:8000"
  echo "  Dashboard: http://${APP_DOMAIN}:3000"
fi

echo "Done."

unset GITHUB_USERNAME
unset GITHUB_PAT
