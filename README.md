# Smart Estate

<div align="center">
	<h1><b>Smart Estate</b></h1>
	<p>
		AI-powered maintenance management for modern residential buildings.
		<br />
		Tenants, technicians, and managers use one platform to create, track, and resolve maintenance work.
	</p>
</div>

## Overview

Smart Estate is a maintenance operations platform for apartments, buildings, and property teams. It combines a FastAPI backend, a React dashboard, AI-assisted ticket classification, technician assignment, media uploads, audit logs, and realtime notifications.

## Features

- Resident maintenance requests with ticket tracking
- AI-assisted issue classification and prioritization
- Technician assignment and scheduling
- Building, apartment, and user management
- Realtime notifications over WebSocket
- Photo and media uploads for issue reporting
- Admin dashboard with operational reporting and audit logs
- Docker-based deployment for Linux VPS environments

## Requirements

For self-hosting, you will need:

- Debian or Ubuntu Linux VPS
- Docker and Docker Compose
- Nginx
- Certbot for SSL
- GitHub access to the backend and dashboard repositories
- PostgreSQL 15+ (handled automatically by the provided compose stack)
- Optional API keys:
	- OpenAI
	- Sentry
	- OpenRouteService

For end users, a modern browser is enough.

## Getting Started

### Self-hosted setup

This repository includes a VPS bootstrap script for self-hosting.

```bash
git clone https://github.com/smartestate/smart-estate.git /opt/smartestate-deploy
cd /opt/smartestate-deploy
chmod +x setup.sh
sudo ./setup.sh
```

The setup script will:

- install Docker, Docker Compose, Nginx, Certbot, UFW, and Git
- create `/opt/smartestate`
- clone or update the backend and dashboard repositories
- generate secrets if they do not already exist
- write a shared `/opt/smartestate/.env`
- start the stack with Docker Compose

The repo also includes `env.sample` with non-secret defaults that the setup script uses as first-run prompts.

The script prompts interactively for GitHub credentials each run when private repositories are used.

Use your own private backend and dashboard Git URLs when prompted. The defaults shown by the script are placeholders.

Security note for PAT usage:

- Use a PAT with the minimum required repo read permissions.
- Enter the PAT only at the hidden prompt in `setup.sh`.
- Do not paste PATs into shell commands or save them in `.env` files.

## Setup Details

The deployment layout expects:

- `/opt/smartestate/.env` for shared configuration
- `/opt/smartestate/uploads` for uploaded media
- `/opt/smartestate/saved_models` for local AI models
- `/opt/smartestate/smart-estate-backend` for the API
- `/opt/smartestate/smart-estate-dashboard` for the web dashboard

The setup script will keep existing `JWT_SECRET_KEY` and `DB_PASSWORD` values if the shared `.env` already exists.

## FAQ

### Is Smart Estate only for property managers?

No. Tenants can submit requests, technicians can manage assignments, and managers can oversee operations from the dashboard.

### Do I need Docker?

Yes, if you are deploying on your own VPS with the included script.

### Can I use custom domains?

Yes. The setup script supports domain-based deployment and can configure Nginx + Certbot.

### What if I do not have OpenAI or Sentry keys?

Leave them blank. The platform will still deploy, but AI and observability features that depend on those services will be limited.

### Can I update the deployment later?

Yes. Rerun the setup script. Existing secrets in `/opt/smartestate/.env` are preserved.

## Troubleshooting

### The app does not start

- Confirm Docker is installed and running.
- Check `docker compose logs -f` inside `/opt/smartestate`.
- Verify `/opt/smartestate/.env` exists and includes `DB_USER`, `DB_PASSWORD`, and `JWT_SECRET_KEY`.

### Private GitHub repositories fail to clone

- Enter your GitHub username and PAT at the setup prompt.
- Make sure the PAT has read access to both private repositories.

### Media uploads fail

- Confirm `/opt/smartestate/uploads` exists.
- Verify the backend container can write to the mounted uploads directory.

### SSL certificate issuance fails

- Ensure DNS points to the VPS before running Certbot.
- Check that ports 80 and 443 are open on the VPS firewall and cloud provider firewall.

## Contact

- For product questions, contact your Smart Estate administrator or support team.
- For self-hosted deployments, open a GitHub issue in this repository.

## Release Notes

Pre-production releases use beta tags:

- Tag format: `v0.x.y-beta.z`
- Example: `v0.1.0-beta.1`

Create a release from the tag and mark it as a pre-release in GitHub.

## License

Add your project license here before public distribution.
