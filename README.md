# Smart Estate Deployment

## 1. What this repo does
This repository provides deployment orchestration for Smart Estate.
It contains Docker Compose, environment templates, and a setup.sh installer for VPS deployment.

## 2. Tech stack
- Docker + Docker Compose
- Bash installer automation
- Nginx reverse proxy
- Certbot for TLS

## 3. How it connects to other repos
- Clones and deploys smart-estate-backend and smart-estate-dashboard.
- Uses runtime settings expected by backend and dashboard.
- Deployment flow is documented in smart-estate-docs.

## 4. Setup instructions (working)
Linux (Debian/Ubuntu) target:

```bash
git clone https://github.com/smartestate/smart-estate.git /opt/smartestate-deploy
cd /opt/smartestate-deploy
chmod +x setup.sh
sudo ./setup.sh
```

Update existing install:

```bash
cd /opt/smartestate-deploy
git pull --ff-only
sudo ./setup.sh --no-self-update
```

Required runtime artifacts created under /opt/smartestate:
- .env
- uploads/
- saved_models/
- smart-estate-backend/
- smart-estate-dashboard/

## 5. Key features (implemented)
- Automated install/update for Docker, Nginx, and deployment dependencies.
- Interactive setup for repo URLs, domains, and optional external keys.
- Compose-based startup for postgres, backend, and dashboard services.
- Persistent storage mounts for DB data, uploads, and AI model artifacts.

## 6. Known limitations
- setup.sh currently targets Debian/Ubuntu only.
- DNS and SSL provisioning require reachable domain records before certificate issuance.
- Interactive installer is optimized for manual ops flows (not fully non-interactive CI).

Security note:
Store production secrets (JWT_SECRET_KEY, DB_PASSWORD, API keys) in a secret manager and inject at deploy time. Do not commit real values.
