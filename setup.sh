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

if [[ -t 1 ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  ORANGE=$'\033[38;2;188;183;251m'
  CYAN=$'\033[38;2;153;177;255m'
  GREEN=$'\033[38;2;153;177;255m'
  YELLOW=$'\033[38;2;188;183;251m'
  RED=$'\033[38;2;249;250;250m'
  LIGHT=$'\033[38;2;249;250;250m'
else
  RESET=''
  BOLD=''
  DIM=''
  ORANGE=''
  CYAN=''
  GREEN=''
  YELLOW=''
  RED=''
  LIGHT=''
fi

section() {
  printf '\n%s%s=== %s ===%s\n' "${BOLD}" "${ORANGE}" "$1" "${RESET}"
}

note() {
  printf '%s%s%s\n' "${DIM}" "$1" "${RESET}"
}

ok() {
  printf '%s[ok]%s %s\n' "${GREEN}" "${RESET}" "$1"
}

warn() {
  printf '%s[warn]%s %s\n' "${YELLOW}" "${RESET}" "$1"
}

fail() {
  printf '%s[error]%s %s\n' "${RED}" "${RESET}" "$1"
  exit 1
}

summary_box() {
  local title="$1"
  shift
  local width=68
  local border
  border="$(printf '%*s' "${width}" '' | tr ' ' '-')"

  printf '\n%s+%s+%s\n' "${LIGHT}" "${border}" "${RESET}"
  printf '%s| %-*s |%s\n' "${LIGHT}" "$((width - 2))" "${title}" "${RESET}"
  printf '%s+%s+%s\n' "${LIGHT}" "${border}" "${RESET}"
  for line in "$@"; do
    printf '%s| %-*s |%s\n' "${LIGHT}" "$((width - 2))" "${line}" "${RESET}"
  done
  printf '%s+%s+%s\n' "${LIGHT}" "${border}" "${RESET}"
}

self_update_from_origin_main() {
  if [[ "${SKIP_SELF_UPDATE:-0}" == "1" ]]; then
    note "Self-update disabled via --no-self-update"
    return
  fi

  if [[ "${SETUP_SELF_UPDATED:-0}" == "1" ]]; then
    return
  fi

  if ! git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  if ! git -C "${SCRIPT_DIR}" remote get-url origin >/dev/null 2>&1; then
    return
  fi

  if ! git -C "${SCRIPT_DIR}" fetch --quiet origin main; then
    warn "Could not check for setup updates from origin/main. Continuing with current script."
    return
  fi

  local current_head
  local remote_head
  current_head="$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || true)"
  remote_head="$(git -C "${SCRIPT_DIR}" rev-parse origin/main 2>/dev/null || true)"

  if [[ -z "${current_head}" || -z "${remote_head}" || "${current_head}" == "${remote_head}" ]]; then
    return
  fi

  local has_local_changes=0
  if ! git -C "${SCRIPT_DIR}" diff --quiet || ! git -C "${SCRIPT_DIR}" diff --cached --quiet || [[ -n "$(git -C "${SCRIPT_DIR}" ls-files --others --exclude-standard)" ]]; then
    has_local_changes=1
    local stash_name="smartestate-setup-autostash-$(date +%s)"
    if git -C "${SCRIPT_DIR}" stash push -u -m "${stash_name}" >/dev/null; then
      warn "Local deploy-repo changes were auto-stashed: ${stash_name}"
    else
      warn "Local changes were detected but could not be auto-stashed. Continuing with current script."
      return
    fi
  fi

  if git -C "${SCRIPT_DIR}" pull --ff-only --quiet origin main; then
    ok "Installer updated from origin/main. Launching latest setup script..."
    export SETUP_SELF_UPDATED=1
    exec bash "${SCRIPT_DIR}/setup.sh" "$@"
  fi

  warn "Could not fast-forward deploy repo from origin/main. Continuing with current script."
  if [[ "${has_local_changes}" == "1" ]]; then
    note "Auto-stashed changes are preserved in git stash."
  fi
}

headline() {
  cat <<'EOF'

  ____                      _      _____     _        _
 / ___| _ __ ___   __ _ _ __| |_   | ____|___| |_ __ _| |_ ___
 \___ \| '_ ` _ \ / _` | '__| __|  |  _| / __| __/ _` | __/ _ \
  ___) | | | | | | (_| | |  | |_   | |___\__ \ || (_| | ||  __/
 |____/|_| |_| |_|\__,_|_|   \__|  |_____|___/\__\__,_|\__\___|

                 Property maintenance, reimagined

EOF
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local response=""

  if [[ -n "${default_value}" ]]; then
    printf '%s%s%s [%s]: %s' "${BOLD}" "${CYAN}" "${label}" "${default_value}" "${RESET}" >&2
  else
    printf '%s%s%s: %s' "${BOLD}" "${CYAN}" "${label}" "${RESET}" >&2
  fi

  read -r response < /dev/tty
  printf '%s' "${response:-${default_value}}"
}

prompt_secret_value() {
  local label="$1"
  local response=""

  printf '%s%s%s: %s' "${BOLD}" "${CYAN}" "${label}" "${RESET}" >&2
  read -r -s response < /dev/tty
  printf '\n' >&2
  printf '%s' "${response}"
}

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

wait_for_dns_match() {
  local hostname="$1"
  local expected_ip="$2"
  local timeout_seconds="${3:-300}"
  local interval_seconds="${4:-15}"
  local elapsed_seconds=0
  local resolved_ip=""

  while (( elapsed_seconds <= timeout_seconds )); do
    resolved_ip="$(resolve_ipv4 "${hostname}")"
    if [[ -n "${resolved_ip}" && "${resolved_ip}" == "${expected_ip}" ]]; then
      printf '%s' "${resolved_ip}"
      return 0
    fi

    if (( elapsed_seconds == timeout_seconds )); then
      break
    fi

    sleep "${interval_seconds}"
    elapsed_seconds=$((elapsed_seconds + interval_seconds))
  done

  printf '%s' "${resolved_ip}"
  return 1
}

print_usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Options:
  --no-self-update    Skip auto-update from origin/main
  -h, --help          Show this help message
EOF
}

SKIP_SELF_UPDATE=0
for arg in "$@"; do
  case "${arg}" in
    --no-self-update)
      SKIP_SELF_UPDATE=1
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      fail "Unknown option: ${arg}. Use --help to see valid options."
      ;;
  esac
done

headline
note "This setup will configure Docker, Nginx, Certbot, firewall, and app deployment."
self_update_from_origin_main "$@"

section "Repository Access"
GITHUB_USERNAME="$(prompt_value "GitHub username for private repos (leave blank for public repos)" "")"
if [[ -n "${GITHUB_USERNAME}" ]]; then
  GITHUB_PAT="$(prompt_secret_value "GitHub PAT with repo read access")"
fi

auth_repo_url() {
  local repo_url="$1"

  if [[ -z "${GITHUB_USERNAME}" || -z "${GITHUB_PAT}" ]]; then
    printf '%s' "${repo_url}"
    return
  fi

  printf '%s' "${repo_url/https:\/\/github.com/https://${GITHUB_USERNAME}:${GITHUB_PAT}@github.com}"
}

section "Application Sources"
BACKEND_REPO="$(prompt_value "Backend Git URL" "https://github.com/YOUR_ORG/smart-estate-backend.git")"

DASHBOARD_REPO="$(prompt_value "Dashboard Git URL" "https://github.com/YOUR_ORG/smart-estate-dashboard.git")"

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

section "Domains and SSL"
warn "If you plan to use custom domains, create the DNS A records at your registrar first."
note "Point both api and app subdomains to this VPS IP before continuing with SSL setup."
USE_DOMAINS="$(prompt_value "Use custom domains? (y/N)" "N")"

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  CERTBOT_EMAIL=""
  CERTBOT_EMAIL="$(prompt_value "SSL certificate email (optional, leave blank to skip)" "")"

  if [[ -n "${EXISTING_API_DOMAIN}" && -n "${EXISTING_APP_DOMAIN}" ]]; then
    API_DOMAIN="${EXISTING_API_DOMAIN}"
    APP_DOMAIN="${EXISTING_APP_DOMAIN}"
    ok "Keeping existing API_DOMAIN and APP_DOMAIN from ${ENV_FILE}."
  elif [[ -n "${EXISTING_VITE_API_URL}" && -n "${EXISTING_CORS_ORIGINS}" ]]; then
    API_DOMAIN="$(extract_host_from_url "${EXISTING_VITE_API_URL}")"
    APP_DOMAIN="$(printf '%s' "${EXISTING_CORS_ORIGINS}" | cut -d, -f1 | sed -E 's#^https?://##; s#/.*$##; s/:.*$##')"
    ok "Derived API_DOMAIN and APP_DOMAIN from existing deployment settings."
  else
    API_DOMAIN="$(prompt_value "API domain" "api.your-domain.com")"

    APP_DOMAIN="$(prompt_value "App domain" "app.your-domain.com")"
  fi
else
  VPS_IP="$(hostname -I | awk '{print $1}')"
  API_DOMAIN="${VPS_IP}"
  APP_DOMAIN="${VPS_IP}"
fi

section "Secrets and Runtime Settings"

OPENAI_API_KEY="${EXISTING_OPENAI_API_KEY}"
if [[ -z "${OPENAI_API_KEY}" ]]; then
  OPENAI_API_KEY="$(prompt_value "OpenAI API key (optional, leave blank to skip)" "")"
fi

ORS_API_KEY="${EXISTING_ORS_API_KEY}"
if [[ -z "${ORS_API_KEY}" ]]; then
  ORS_API_KEY="$(prompt_value "OpenRouteService API key (optional, leave blank to skip)" "")"
fi

SENTRY_DSN="${EXISTING_SENTRY_DSN}"
if [[ -z "${SENTRY_DSN}" ]]; then
  SENTRY_DSN="$(prompt_value "Sentry DSN (optional, leave blank to skip)" "")"
fi

if [[ -n "${EXISTING_DB_USER}" ]]; then
  DB_USER="${EXISTING_DB_USER}"
  ok "Keeping existing DB_USER from ${ENV_FILE}."
else
  DB_USER="$(prompt_value "DB user" "${SAMPLE_DB_USER:-smartestate}")"
fi

if [[ -n "${EXISTING_DB_NAME}" ]]; then
  DB_NAME="${EXISTING_DB_NAME}"
  ok "Keeping existing DB_NAME from ${ENV_FILE}."
else
  DB_NAME="$(prompt_value "DB name" "${SAMPLE_DB_NAME:-smartestate}")"
fi

if [[ -n "${EXISTING_JWT_SECRET_KEY}" ]]; then
  JWT_SECRET_KEY="${EXISTING_JWT_SECRET_KEY}"
  ok "Keeping existing JWT_SECRET_KEY from ${ENV_FILE}."
else
  JWT_SECRET_KEY="$(openssl rand -hex 32)"
  ok "Generated JWT_SECRET_KEY."
fi

if [[ -n "${EXISTING_DB_PASSWORD}" ]]; then
  DB_PASSWORD="${EXISTING_DB_PASSWORD}"
  ok "Keeping existing DB_PASSWORD from ${ENV_FILE}."
else
  DB_PASSWORD="$(openssl rand -hex 16)"
  ok "Generated DB_PASSWORD."
fi

section "System Setup"
note "Updating packages..."
apt update && apt upgrade -y

note "Installing dependencies..."
apt install -y docker.io nginx certbot python3-certbot-nginx ufw git openssl curl

# Compose package names vary by distro/repo. Try common options.
if ! apt install -y docker-compose-plugin; then
  apt install -y docker-compose-v2 || apt install -y docker-compose || true
fi

note "Configuring firewall..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

note "Enabling Docker..."
systemctl enable docker
systemctl start docker

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  fail "Docker Compose is not installed. Install one of: docker-compose-plugin, docker-compose-v2, or docker-compose"
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

section "Application Deployment"
note "Cloning or updating application repositories..."
clone_or_pull "${BACKEND_REPO}" "${DEPLOY_ROOT}/smart-estate-backend"
clone_or_pull "${DASHBOARD_REPO}" "${DEPLOY_ROOT}/smart-estate-dashboard"

if [[ ! -f "${DEPLOY_ROOT}/smart-estate-backend/Dockerfile" ]]; then
  fail "Backend Dockerfile missing in ${DEPLOY_ROOT}/smart-estate-backend"
fi

if [[ ! -f "${DEPLOY_ROOT}/smart-estate-dashboard/Dockerfile" ]]; then
  fail "Dashboard Dockerfile missing in ${DEPLOY_ROOT}/smart-estate-dashboard"
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

note "Starting stack with Docker Compose..."
cd "${DEPLOY_ROOT}"
"${COMPOSE_CMD[@]}" --env-file .env up -d --build

section "Validation"
note "Running post-deploy smoke checks..."
if curl -fsS "http://127.0.0.1:8000/health" >/dev/null; then
  ok "Backend is healthy on localhost:8000"
else
  warn "Backend health check failed on localhost:8000"
  note "Check logs: ${COMPOSE_CMD[*]} -f ${DEPLOY_ROOT}/docker-compose.yml logs --tail=100 backend"
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

    note "Running SSL provisioning now that DNS points to this VPS..."
    "${CERTBOT_CMD[@]}"

    if curl -fsS "https://${API_DOMAIN}/health" >/dev/null; then
      ok "API HTTPS health check passed"
    else
      warn "API HTTPS health check failed after certificate provisioning"
    fi
  else
    warn "DNS is not yet pointing at this VPS for both domains"
    note "API resolves to: ${API_DNS_IP:-<unresolved>}"
    note "App resolves to: ${APP_DNS_IP:-<unresolved>}"
    note "Current VPS IP: ${CURRENT_IP}"
    note "Waiting up to 5 minutes for DNS propagation before skipping SSL..."

    API_DNS_IP="$(wait_for_dns_match "${API_DOMAIN}" "${CURRENT_IP}" 300 15 || true)"
    APP_DNS_IP="$(wait_for_dns_match "${APP_DOMAIN}" "${CURRENT_IP}" 300 15 || true)"

    if [[ -n "${API_DNS_IP}" && -n "${APP_DNS_IP}" && "${API_DNS_IP}" == "${CURRENT_IP}" && "${APP_DNS_IP}" == "${CURRENT_IP}" ]]; then
      CERTBOT_CMD=(certbot --nginx -d "${API_DOMAIN}" -d "${APP_DOMAIN}" --non-interactive --agree-tos)
      if [[ -n "${CERTBOT_EMAIL}" ]]; then
        CERTBOT_CMD+=(--email "${CERTBOT_EMAIL}")
      else
        CERTBOT_CMD+=(--register-unsafely-without-email)
      fi

      note "Running SSL provisioning after DNS propagation wait..."
      "${CERTBOT_CMD[@]}"

      if curl -fsS "https://${API_DOMAIN}/health" >/dev/null; then
        ok "API HTTPS health check passed"
      else
        warn "API HTTPS health check failed after certificate provisioning"
      fi
    else
      warn "DNS still does not resolve to this VPS after waiting"
      note "SSL provisioning was skipped for now. Re-run setup after DNS propagates."
    fi
  fi

  CORS_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS "https://${API_DOMAIN}/auth/login" -H "Origin: https://${APP_DOMAIN}" -H "Access-Control-Request-Method: POST" || true)"
  if printf '%s' "${CORS_HEADERS}" | grep -iq "access-control-allow-origin: https://${APP_DOMAIN}"; then
    ok "CORS preflight looks correct for app domain"
  else
    warn "CORS preflight did not return expected allow-origin"
    note "Expected origin: https://${APP_DOMAIN}"
    note "Current CORS_ORIGINS in ${ENV_FILE}: $(grep -E '^CORS_ORIGINS=' "${ENV_FILE}" | cut -d= -f2-)"
  fi
else
  CORS_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS "http://${API_DOMAIN}:8000/auth/login" -H "Origin: http://${APP_DOMAIN}:3000" -H "Access-Control-Request-Method: POST" || true)"
  if printf '%s' "${CORS_HEADERS}" | grep -iq "access-control-allow-origin: http://${APP_DOMAIN}:3000"; then
    ok "CORS preflight looks correct for local IP mode"
  else
    warn "CORS preflight did not return expected allow-origin for local IP mode"
  fi

  note "Custom domains not configured. Use these URLs:"
  note "API: http://${API_DOMAIN}:8000"
  note "Dashboard: http://${APP_DOMAIN}:3000"
fi

section "Done"
ok "Setup complete"

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  summary_box \
    "Smart Estate deployment ready" \
    "API: https://${API_DOMAIN}" \
    "App: https://${APP_DOMAIN}" \
    "Config: ${ENV_FILE}" \
    "Uploads: ${DEPLOY_ROOT}/uploads" \
    "Saved models: ${DEPLOY_ROOT}/saved_models"
else
  summary_box \
    "Smart Estate deployment ready" \
    "API: http://${API_DOMAIN}:8000" \
    "App: http://${APP_DOMAIN}:3000" \
    "Config: ${ENV_FILE}" \
    "Uploads: ${DEPLOY_ROOT}/uploads" \
    "Saved models: ${DEPLOY_ROOT}/saved_models"
fi

unset GITHUB_USERNAME
unset GITHUB_PAT
