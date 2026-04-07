# Smart Estate Deployment Repo

This repository is the production deployment orchestrator for Smart Estate on a Debian/Ubuntu Linux VPS.

It provisions:
- Docker + Docker Compose
- UFW firewall baseline
- Nginx reverse proxy
- Certbot TLS setup (optional, after DNS)
- App stack under /opt/smartestate

It also wires these application repositories:
- smart-estate-backend
- smart-estate-dashboard

## Quick Start

Run on the VPS as root (or with sudo):

```bash
git clone https://github.com/smartestate/smart-estate.git /opt/smartestate-deploy
cd /opt/smartestate-deploy
chmod +x setup.sh
sudo ./setup.sh
```

The setup script is interactive and will ask for:
- Git URLs for backend and dashboard
- Domain configuration (or VPS-IP fallback)
- OpenAI API key (optional)
- Sentry DSN (optional)

## Release Strategy

Use pre-production tags and releases in this repository:
- Tag format: v0.x.y-beta.z
- Example: v0.1.0-beta.1

Suggested flow:

```bash
git checkout main
git pull origin main
git tag v0.1.0-beta.1
git push origin v0.1.0-beta.1
```

Then create a GitHub Release from that tag and mark it as pre-release.

## Notes

- The script targets Debian-based systems (Ubuntu/Debian).
- Final app runtime root is /opt/smartestate.
- Shared env file is /opt/smartestate/.env.
- Backend uploads are persisted at /opt/smartestate/uploads.
- If /opt/smartestate/.env already exists, the setup script keeps existing JWT_SECRET_KEY and DB_PASSWORD values and only generates missing secrets.
