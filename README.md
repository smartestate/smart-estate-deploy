# Smart Estate Deployment

## What this repo does
This repository contains the deployment automation for Smart Estate infrastructure and runtime services.
It provisions and updates a Docker-based stack for PostgreSQL, backend API, and dashboard UI.

## Tech stack
- Bash installer (`setup.sh`)
- Docker + Docker Compose
- Nginx reverse proxy
- Certbot TLS automation
- UFW firewall setup

## How it connects to other repos
- Pulls and updates `smart-estate-backend` and `smart-estate-dashboard` into `/opt/smartestate`.
- Runs backend migrations from `smart-estate-backend/migrations`.
- Mounts persistent runtime folders consumed by backend (`uploads`, `saved_models`).
- Deployment documentation is maintained in `smart-estate-docs`.

## Setup instructions
Supported OS:
- Debian/Ubuntu (enforced by installer)

First-time install:

```bash
git clone https://github.com/smartestate/smart-estate.git /opt/smartestate-deploy
cd /opt/smartestate-deploy
chmod +x setup.sh
sudo ./setup.sh
```

Update existing deployment:

```bash
cd /opt/smartestate-deploy
git pull --ff-only
sudo ./setup.sh --no-self-update
```

Actual deploy/update flow implemented by `setup.sh`:
1. Validates OS and installer options.
2. Optionally self-updates from `origin/main`.
3. Installs system dependencies and configures firewall.
4. Collects repo/domain/runtime settings interactively.
5. Clones or updates backend/dashboard repos.
6. Writes `/opt/smartestate/.env`.
7. Copies compose file and writes Nginx site config.
8. Runs DB backup + incremental SQL migrations.
9. Builds/starts containers.
10. Runs health/CORS checks and optional TLS provisioning.

## Environment variables
Required for production runtime:
- `DB_USER`
- `DB_PASSWORD`
- `DB_NAME`
- `JWT_SECRET_KEY`
- `CORS_ORIGINS`
- `VITE_API_URL`
- `API_DOMAIN`
- `APP_DOMAIN`

Optional:
- `OPENAI_API_KEY`
- `ORS_API_KEY`
- `OPENROUTESERVICE_API_KEY`
- `SENTRY_DSN`
- `CERTBOT_EMAIL`
- `ENVIRONMENT`
- `UPLOAD_DIR`
- `JWT_ALGORITHM`
- `JWT_EXPIRY_MINUTES`
- `DB_HOST`
- `DB_PORT`
- `GITHUB_USERNAME` (used by `setup.sh` for private repo clone auth)
- `GITHUB_PAT` (used by `setup.sh` for private repo clone auth)
- `BACKEND_REPO` (default backend git URL for `setup.sh` prompts)
- `DASHBOARD_REPO` (default dashboard git URL for `setup.sh` prompts)

Repository source variables:
- `setup.sh` now reads `GITHUB_USERNAME`, `GITHUB_PAT`, `BACKEND_REPO`, and `DASHBOARD_REPO` from `/opt/smartestate/.env` and uses them as defaults.
- Storing `GITHUB_PAT` in `.env` is supported for convenience but is not recommended for production security.
- Prefer entering PAT interactively at runtime or using a dedicated secret manager.

## Runtime folders and files created
- `/opt/smartestate/.env`
- `/opt/smartestate/docker-compose.yml`
- `/opt/smartestate/uploads/`
- `/opt/smartestate/saved_models/`
- `/opt/smartestate/backups/`
- `/opt/smartestate/smart-estate-backend/`
- `/opt/smartestate/smart-estate-dashboard/`
- `/etc/nginx/sites-available/smartestate`

## Current implemented features
- Interactive deployment/install/update workflow.
- Automated dependency installation and service bootstrapping.
- Backup + tracked migration execution (`schema_migrations`).
- Health and CORS verification checks after rollout.
- Optional DNS-aware TLS issuance via Certbot.

## Known limitations
- Non-interactive CI deployment is limited; installer is operator-driven.
- Debian/Ubuntu only.
- TLS setup depends on DNS propagation to the target host.

## Status
Deployment automation is implemented and production-oriented for VM/server setups.

Security note:
Use a secret manager for production credentials and API keys. Do not commit live secrets to source control.
