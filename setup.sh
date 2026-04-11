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
VERBOSE=0
LOG_FILE="/tmp/smartestate-setup.log"

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
  if [[ "${VERBOSE}" == "1" ]]; then
    printf '%s%s%s\n' "${DIM}" "$1" "${RESET}"
  fi
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

run_cmd() {
  local description="$1"
  shift

  if [[ "${VERBOSE}" == "1" ]]; then
    note "${description}"
    "$@"
    return
  fi

  printf '[..] %s' "${description}"
  "$@" >>"${LOG_FILE}" 2>&1 &
  local cmd_pid=$!
  local spinner='|/-\\'
  local spin_idx=0
  local cmd_status=0

  trap 'kill "${cmd_pid}" >/dev/null 2>&1 || true; wait "${cmd_pid}" >/dev/null 2>&1 || true; printf "\n"; exit 130' INT TERM

  while kill -0 "${cmd_pid}" >/dev/null 2>&1; do
    printf '\r[..] %s %c' "${description}" "${spinner:spin_idx++%${#spinner}:1}"
    sleep 0.15
  done

  set +e
  wait "${cmd_pid}"
  cmd_status=$?
  set -e
  trap - INT TERM

  printf '\r\033[2K'
  if [[ "${cmd_status}" == "0" ]]; then
    printf '[ok] %s\n' "${description}"
    return
  fi

  warn "${description} failed. See ${LOG_FILE}"
  tail -n 40 "${LOG_FILE}" >&2 || true
  exit 1
}

run_cmd_optional() {
  local description="$1"
  shift

  if [[ "${VERBOSE}" == "1" ]]; then
    note "${description}"
    "$@"
    return $?
  fi

  printf '[..] %s' "${description}"
  "$@" >>"${LOG_FILE}" 2>&1 &
  local cmd_pid=$!
  local spinner='|/-\\'
  local spin_idx=0
  local cmd_status=0

  trap 'kill "${cmd_pid}" >/dev/null 2>&1 || true; wait "${cmd_pid}" >/dev/null 2>&1 || true; printf "\n"; exit 130' INT TERM

  while kill -0 "${cmd_pid}" >/dev/null 2>&1; do
    printf '\r[..] %s %c' "${description}" "${spinner:spin_idx++%${#spinner}:1}"
    sleep 0.15
  done

  set +e
  wait "${cmd_pid}"
  cmd_status=$?
  set -e
  trap - INT TERM

  printf '\r\033[2K'
  if [[ "${cmd_status}" == "0" ]]; then
    printf '[ok] %s\n' "${description}"
  fi

  return "${cmd_status}"
}

apt_get_cmd() {
  local apt_args=()
  if [[ "${VERBOSE}" == "1" ]]; then
    apt_args+=("-o" "Dpkg::Use-Pty=0")
  fi

  DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=600 \
    -o Acquire::Retries=3 \
    "${apt_args[@]}" \
    "$@"
}

export -f apt_get_cmd

git_cmd() {
  if [[ "${VERBOSE}" == "1" ]]; then
    git "$@"
  else
    git "$@" >>"${LOG_FILE}" 2>&1
  fi
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

  _____ __  __    _    ____ _____    _____ ____ _____  _  _____ _____
 / ____|  \/  |  / \  |  _ \_   _|  | ____/ ___|_   _|/ \|_   _| ____|
| (___ | |\/| | / _ \ | |_) || |    |  _| \___ \ | | / _ \ | | |  _|
 \___ \| |  | |/ ___ \|  _ < | |    | |___ ___) || |/ ___ \| | | |___
 ____/ |_|  |_/_/   \_\_| \_\|_|    |_____|____/ |_/_/   \_\_| |_____|

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

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local response=""

  while true; do
    response="$(prompt_value "${label}" "${default_value}")"
    response="${response,,}"
    if [[ -z "${response}" ]]; then
      response="${default_value,,}"
    fi

    case "${response}" in
      y|yes)
        printf 'Y'
        return
        ;;
      n|no)
        printf 'N'
        return
        ;;
      *)
        warn "Please answer with y or n."
        ;;
    esac
  done
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

is_valid_email() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

is_valid_repo_url() {
  local value="$1"
  [[ "${value}" =~ ^https://[^[:space:]]+\.git$ || "${value}" =~ ^git@[^:]+:[^[:space:]]+\.git$ ]]
}

is_valid_openai_key() {
  local value="$1"
  [[ "${value}" == sk-proj-* ]]
}

is_valid_sentry_dsn() {
  local value="$1"
  [[ "${value}" == *sentry.io* ]]
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

wait_for_http_ok() {
  local url="$1"
  local timeout_seconds="${2:-90}"
  local interval_seconds="${3:-3}"
  local elapsed_seconds=0

  while (( elapsed_seconds <= timeout_seconds )); do
    if curl -fs --max-time 5 "${url}" >/dev/null 2>&1; then
      return 0
    fi

    if (( elapsed_seconds == timeout_seconds )); then
      break
    fi

    sleep "${interval_seconds}"
    elapsed_seconds=$((elapsed_seconds + interval_seconds))
  done

  return 1
}

print_usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Options:
  -v, --verbose       Enable detailed installer logs
  --no-self-update    Skip auto-update from origin/main
  -h, --help          Show this help message
EOF
}

SKIP_SELF_UPDATE=0
for arg in "$@"; do
  case "${arg}" in
    -v|--verbose)
      VERBOSE=1
      ;;
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

if [[ "${VERBOSE}" != "1" ]]; then
  : >"${LOG_FILE}"
fi

self_update_from_origin_main "$@"

headline
note "This setup will configure Docker, Nginx, Certbot, firewall, and app deployment."
note "Press Enter to accept defaults shown in [brackets]."
note "You can safely rerun this script later for updates."

section "Repository Access"
note "If backend/dashboard repos are private: enter GitHub username + PAT."
note "If repos are public: leave username blank and continue."

EXISTING_GITHUB_USERNAME="$(get_env_value GITHUB_USERNAME)"
EXISTING_GITHUB_PAT="$(get_env_value GITHUB_PAT)"
EXISTING_BACKEND_REPO="$(get_env_value BACKEND_REPO)"
EXISTING_DASHBOARD_REPO="$(get_env_value DASHBOARD_REPO)"

GITHUB_USERNAME="$(prompt_value "GitHub username for private repos (leave blank for public repos)" "${EXISTING_GITHUB_USERNAME}")"
if [[ -n "${GITHUB_USERNAME}" ]]; then
  if [[ -n "${EXISTING_GITHUB_PAT}" ]]; then
    GITHUB_PAT="${EXISTING_GITHUB_PAT}"
    warn "Using GITHUB_PAT from ${ENV_FILE}. Storing PAT in .env is not recommended for production."
  else
    note "PAT input is hidden. Paste token and press Enter."
    GITHUB_PAT="$(prompt_secret_value "GitHub PAT with repo read access")"
  fi
else
  GITHUB_PAT=""
  note "Using public clone mode (no GitHub credentials)."
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
note "Provide repository clone URLs for backend and dashboard."
note "Tip: use your org URLs (defaults are placeholders)."
while true; do
  BACKEND_REPO="$(prompt_value "Backend Git URL" "${EXISTING_BACKEND_REPO:-https://github.com/YOUR_ORG/smart-estate-backend.git}")"
  if [[ "${BACKEND_REPO}" == *"YOUR_ORG"* ]]; then
    warn "Please replace YOUR_ORG with your real GitHub org/user in Backend Git URL."
    continue
  fi
  if is_valid_repo_url "${BACKEND_REPO}"; then
    break
  fi
  warn "Backend Git URL must be an https/ssh git URL ending with .git"
done

while true; do
  DASHBOARD_REPO="$(prompt_value "Dashboard Git URL" "${EXISTING_DASHBOARD_REPO:-https://github.com/YOUR_ORG/smart-estate-dashboard.git}")"
  if [[ "${DASHBOARD_REPO}" == *"YOUR_ORG"* ]]; then
    warn "Please replace YOUR_ORG with your real GitHub org/user in Dashboard Git URL."
    continue
  fi
  if is_valid_repo_url "${DASHBOARD_REPO}"; then
    break
  fi
  warn "Dashboard Git URL must be an https/ssh git URL ending with .git"
done

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
EXISTING_CERTBOT_EMAIL="$(get_env_value CERTBOT_EMAIL)"
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
VPS_IP="$(hostname -I | awk '{print $1}')"
DEFAULT_USE_DOMAINS="N"
if [[ -n "${EXISTING_API_DOMAIN}" && -n "${EXISTING_APP_DOMAIN}" && "${EXISTING_API_DOMAIN}" != "${VPS_IP}" && "${EXISTING_APP_DOMAIN}" != "${VPS_IP}" ]]; then
  DEFAULT_USE_DOMAINS="Y"
fi
USE_DOMAINS="$(prompt_yes_no "Use custom domains? (y/N)" "${DEFAULT_USE_DOMAINS}")"

if [[ "${USE_DOMAINS}" =~ ^[Yy]$ ]]; then
  if [[ -n "${EXISTING_CERTBOT_EMAIL}" ]] && is_valid_email "${EXISTING_CERTBOT_EMAIL}"; then
    CERTBOT_EMAIL="${EXISTING_CERTBOT_EMAIL}"
    ok "Keeping existing CERTBOT_EMAIL from ${ENV_FILE}."
  else
    CERTBOT_EMAIL=""
    if [[ -n "${EXISTING_CERTBOT_EMAIL}" ]]; then
      warn "Existing CERTBOT_EMAIL is invalid and must be updated."
    fi
    note "Email is recommended for expiry notices (optional)."
    while true; do
      CERTBOT_EMAIL="$(prompt_value "SSL certificate email (optional, leave blank to skip)" "")"
      if [[ -z "${CERTBOT_EMAIL}" ]] || is_valid_email "${CERTBOT_EMAIL}"; then
        break
      fi
      warn "Please enter a valid email address or leave blank."
    done
  fi

  if [[ -n "${EXISTING_API_DOMAIN}" && -n "${EXISTING_APP_DOMAIN}" ]]; then
    API_DOMAIN="${EXISTING_API_DOMAIN}"
    APP_DOMAIN="${EXISTING_APP_DOMAIN}"
    ok "Keeping existing API_DOMAIN and APP_DOMAIN from ${ENV_FILE}."
  elif [[ -n "${EXISTING_VITE_API_URL}" && -n "${EXISTING_CORS_ORIGINS}" ]]; then
    FIRST_CORS_ORIGIN="${EXISTING_CORS_ORIGINS%%,*}"
    API_DOMAIN="$(extract_host_from_url "${EXISTING_VITE_API_URL}")"
    APP_DOMAIN="$(extract_host_from_url "${FIRST_CORS_ORIGIN}")"

    if [[ -n "${API_DOMAIN}" && -n "${APP_DOMAIN}" ]]; then
      ok "Derived API_DOMAIN and APP_DOMAIN from existing deployment settings."
    else
      warn "Could not safely derive domains from existing settings. Asking explicitly."
      API_DOMAIN="$(prompt_value "API domain" "api.your-domain.com")"
      APP_DOMAIN="$(prompt_value "App domain" "app.your-domain.com")"
    fi
  else
    API_DOMAIN="$(prompt_value "API domain" "api.your-domain.com")"

    APP_DOMAIN="$(prompt_value "App domain" "app.your-domain.com")"
  fi
else
  API_DOMAIN="${VPS_IP}"
  APP_DOMAIN="${VPS_IP}"
  CERTBOT_EMAIL=""
  note "Using IP-based mode without custom domains."
fi

section "Secrets and Runtime Settings"

OPENAI_API_KEY="${EXISTING_OPENAI_API_KEY}"
if [[ -n "${OPENAI_API_KEY}" ]] && ! is_valid_openai_key "${OPENAI_API_KEY}"; then
  warn "Existing OPENAI_API_KEY is invalid. Expected prefix: sk-proj-"
  OPENAI_API_KEY=""
fi
if [[ -z "${OPENAI_API_KEY}" ]]; then
  while true; do
    OPENAI_API_KEY="$(prompt_value "OpenAI API key (optional, leave blank to skip)" "")"
    if [[ -z "${OPENAI_API_KEY}" ]] || is_valid_openai_key "${OPENAI_API_KEY}"; then
      break
    fi
    warn "OpenAI API key must start with sk-proj- or be left blank."
  done
fi

ORS_API_KEY="${EXISTING_ORS_API_KEY}"
if [[ -z "${ORS_API_KEY}" ]]; then
  ORS_API_KEY="$(prompt_value "OpenRouteService API key (optional, leave blank to skip)" "")"
fi

SENTRY_DSN="${EXISTING_SENTRY_DSN}"
if [[ -n "${SENTRY_DSN}" ]] && ! is_valid_sentry_dsn "${SENTRY_DSN}"; then
  warn "Existing SENTRY_DSN is invalid. Expected to include sentry.io"
  SENTRY_DSN=""
fi
if [[ -z "${SENTRY_DSN}" ]]; then
  while true; do
    SENTRY_DSN="$(prompt_value "Sentry DSN (optional, leave blank to skip)" "")"
    if [[ -z "${SENTRY_DSN}" ]] || is_valid_sentry_dsn "${SENTRY_DSN}"; then
      break
    fi
    warn "Sentry DSN must include sentry.io or be left blank."
  done
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

section "Review"
summary_box \
  "Confirm deployment inputs" \
  "Backend repo: ${BACKEND_REPO}" \
  "Dashboard repo: ${DASHBOARD_REPO}" \
  "Use custom domains: ${USE_DOMAINS}" \
  "API target: ${API_DOMAIN}" \
  "App target: ${APP_DOMAIN}" \
  "Deploy path: ${DEPLOY_ROOT}" \
  "Config file: ${ENV_FILE}"

PROCEED_INSTALL="$(prompt_yes_no "Proceed with installation now? (Y/n)" "Y")"
if [[ "${PROCEED_INSTALL}" != "Y" ]]; then
  warn "Installation cancelled by user before system changes."
  exit 0
fi

section "System Setup"
run_cmd "Updating packages" apt_get_cmd update
run_cmd "Upgrading packages" apt_get_cmd upgrade -y

run_cmd "Installing dependencies" apt_get_cmd install -y docker.io nginx certbot python3-certbot-nginx ufw git openssl curl

# Compose package names vary by distro/repo. Try common options.
if ! run_cmd_optional "Installing docker-compose-plugin" apt_get_cmd install -y docker-compose-plugin; then
  if ! run_cmd_optional "Installing docker-compose-v2" apt_get_cmd install -y docker-compose-v2; then
    if ! run_cmd_optional "Installing docker-compose" apt_get_cmd install -y docker-compose; then
      warn "Could not install any Compose package automatically (tried docker-compose-plugin, docker-compose-v2, docker-compose)."
    fi
  fi
fi

run_cmd "Configuring firewall" bash -lc "ufw allow 22 && ufw allow 80 && ufw allow 443 && ufw --force enable"

run_cmd "Enabling Docker service" bash -lc "systemctl enable docker && systemctl start docker"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  fail "Docker Compose is not installed. Install one of: docker-compose-plugin, docker-compose-v2, or docker-compose"
fi

COMPOSE_WITH_ENV=("${COMPOSE_CMD[@]}" --env-file .env)

mkdir -p "${DEPLOY_ROOT}" "${DEPLOY_ROOT}/uploads" "${DEPLOY_ROOT}/saved_models"

clone_or_pull() {
  local repo_url="$1"
  local target_dir="$2"
  local auth_url
  auth_url="$(auth_repo_url "${repo_url}")"

  if [[ -d "${target_dir}/.git" ]]; then
    local original_remote_url
    original_remote_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    if [[ "${auth_url}" != "${original_remote_url}" ]]; then
      git_cmd -C "${target_dir}" remote set-url origin "${auth_url}"
    fi
    trap "git -C '${target_dir}' remote set-url origin '${original_remote_url}' >/dev/null 2>&1 || true" RETURN
    git_cmd -C "${target_dir}" fetch --all
    git_cmd -C "${target_dir}" checkout main || true
    git_cmd -C "${target_dir}" pull --ff-only origin main || true
  else
    git_cmd clone "${auth_url}" "${target_dir}"
    if [[ -n "${GITHUB_USERNAME}" && -n "${GITHUB_PAT}" ]]; then
      git_cmd -C "${target_dir}" remote set-url origin "${repo_url}"
    fi
  fi
}

run_db_migrations() {
  local migration_dir="${DEPLOY_ROOT}/smart-estate-backend/migrations"
  local backup_dir="${DEPLOY_ROOT}/backups"
  local schema_table="schema_migrations"
  local ready=0

  section "Database Migrations"
  run_cmd "Starting database service" "${COMPOSE_WITH_ENV[@]}" up -d postgres

  note "Waiting for Postgres readiness..."
  for _ in {1..30}; do
    if "${COMPOSE_WITH_ENV[@]}" exec -T postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done

  if [[ "${ready}" != "1" ]]; then
    fail "Postgres did not become ready for migrations."
  fi
  ok "Postgres is ready"

  mkdir -p "${backup_dir}"
  local backup_file="${backup_dir}/pre_migration_$(date +%Y%m%d_%H%M%S).sql"
  if "${COMPOSE_WITH_ENV[@]}" exec -T postgres pg_dump -U "${DB_USER}" "${DB_NAME}" > "${backup_file}"; then
    ok "Database backup saved to ${backup_file}"
  else
    fail "Database backup failed before applying migrations."
  fi

  "${COMPOSE_WITH_ENV[@]}" exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -c "
    CREATE TABLE IF NOT EXISTS ${schema_table} (
      filename TEXT PRIMARY KEY,
      applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
    );
  " >/dev/null
  ok "Migration tracker table is ready"

  if [[ ! -d "${migration_dir}" ]]; then
    warn "Migration directory not found at ${migration_dir}; skipping incremental migrations."
    return
  fi

  shopt -s nullglob
  local migration_files=("${migration_dir}"/*.sql)
  shopt -u nullglob

  if [[ ${#migration_files[@]} -eq 0 ]]; then
    note "No migration files found in ${migration_dir}"
    return
  fi

  local migration_file=""
  local migration_name=""
  local migration_name_sql=""
  local applied=""

  for migration_file in "${migration_files[@]}"; do
    migration_name="$(basename "${migration_file}")"
    migration_name_sql="${migration_name//\'/\'\'}"

    applied="$("${COMPOSE_WITH_ENV[@]}" exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT 1 FROM ${schema_table} WHERE filename='${migration_name_sql}' LIMIT 1;" | tr -d '[:space:]')"

    if [[ "${applied}" == "1" ]]; then
      note "Skipping already-applied migration ${migration_name}"
      continue
    fi

    if "${COMPOSE_WITH_ENV[@]}" exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 < "${migration_file}"; then
      "${COMPOSE_WITH_ENV[@]}" exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -c "INSERT INTO ${schema_table}(filename) VALUES ('${migration_name_sql}');" >/dev/null
      ok "Applied migration ${migration_name}"
    else
      fail "Migration failed: ${migration_name}"
    fi
  done
}

section "Application Deployment"
note "Cloning or updating application repositories..."
clone_or_pull "${BACKEND_REPO}" "${DEPLOY_ROOT}/smart-estate-backend"
clone_or_pull "${DASHBOARD_REPO}" "${DEPLOY_ROOT}/smart-estate-dashboard"

if command -v npx >/dev/null 2>&1 && [[ -f "${DEPLOY_ROOT}/smart-estate-dashboard/package.json" ]]; then
  run_cmd "Updating Browserslist database" bash -lc "cd '${DEPLOY_ROOT}/smart-estate-dashboard' && npx update-browserslist-db@latest --yes"
else
  warn "Skipping Browserslist database update because npx or dashboard package.json was not found."
fi

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
OPENROUTESERVICE_API_KEY=${ORS_API_KEY}

CORS_ORIGINS=${CORS_ORIGINS}
SENTRY_DSN=${SENTRY_DSN}
ENVIRONMENT=${ENVIRONMENT}
UPLOAD_DIR=${UPLOAD_DIR}
VITE_API_URL=${VITE_API_URL}
API_DOMAIN=${API_DOMAIN}
APP_DOMAIN=${APP_DOMAIN}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
GITHUB_USERNAME=${GITHUB_USERNAME}
GITHUB_PAT=${GITHUB_PAT}
BACKEND_REPO=${BACKEND_REPO}
DASHBOARD_REPO=${DASHBOARD_REPO}
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

run_cmd "Applying Nginx configuration" bash -lc "ln -sf /etc/nginx/sites-available/smartestate /etc/nginx/sites-enabled/smartestate && nginx -t && systemctl reload nginx"

note "Starting stack with Docker Compose..."
cd "${DEPLOY_ROOT}"
run_db_migrations
run_cmd "Building and starting containers" "${COMPOSE_WITH_ENV[@]}" up -d --build

section "Validation"
note "Running post-deploy smoke checks..."
note "Waiting for backend readiness on localhost (up to 90s)..."
if wait_for_http_ok "http://127.0.0.1:8000/health" 90 3; then
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

    run_cmd "Provisioning SSL certificates" "${CERTBOT_CMD[@]}"

    note "Waiting for API HTTPS readiness (up to 90s)..."
    if wait_for_http_ok "https://${API_DOMAIN}/health" 90 3; then
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

      run_cmd "Provisioning SSL certificates after DNS propagation" "${CERTBOT_CMD[@]}"

      note "Waiting for API HTTPS readiness (up to 90s)..."
      if wait_for_http_ok "https://${API_DOMAIN}/health" 90 3; then
        ok "API HTTPS health check passed"
      else
        warn "API HTTPS health check failed after certificate provisioning"
      fi
    else
      warn "DNS still does not resolve to this VPS after waiting"
      note "SSL provisioning was skipped for now. Re-run setup after DNS propagates."
    fi
  fi

  if wait_for_http_ok "https://${API_DOMAIN}/health" 30 3; then
    CORS_HEADERS="$(curl -sS -D - -o /dev/null -X OPTIONS "https://${API_DOMAIN}/auth/login" -H "Origin: https://${APP_DOMAIN}" -H "Access-Control-Request-Method: POST" || true)"
    if printf '%s' "${CORS_HEADERS}" | grep -iq "access-control-allow-origin: https://${APP_DOMAIN}"; then
      ok "CORS preflight looks correct for app domain"
    else
      warn "CORS preflight did not return expected allow-origin"
      note "Expected origin: https://${APP_DOMAIN}"
      note "Current CORS_ORIGINS in ${ENV_FILE}: $(grep -E '^CORS_ORIGINS=' "${ENV_FILE}" | cut -d= -f2-)"
    fi
  else
    warn "Skipping CORS preflight check because API HTTPS health is not ready"
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
