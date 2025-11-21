# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Ansible role that generates docker-compose files for a home server setup. It creates multiple isolated stacks (Traefik, Nextcloud, monitoring, home automation, vwsfriend) with each stack running on its own Docker network. All services are proxied through Traefik with automatic Let's Encrypt TLS certificates.

## Architecture

### Stack Isolation Strategy
- Each application stack runs in its own Docker network for security isolation
- Only frontend containers communicate with Traefik (on the traefik network)
- Backend containers (databases, caches) remain isolated within their stack networks
- Traefik serves as the single entry point with automatic TLS certificate management

### Stack Components
- **traefik**: Reverse proxy with Let's Encrypt DNS challenge (hosting.de) and error pages
- **nextcloud**: Nextcloud with MariaDB, Redis, and supporting containers
- **monitoring**: Prometheus and Grafana for metrics and dashboards
- **ha** (home automation): Mosquitto MQTT broker and evcc for EV charging management
- **vwsfriend**: VW WeConnect integration with PostgreSQL backend
- **git**: Forgejo self-hosted git service with SSH and web UI access
- **backup**: Environment variable scripts for backup automation

### Role Structure
- `defaults/main.yml`: Default variables (versions, domains, paths)
- `tasks/main.yml`: Main entry point, conditionally includes stack-specific task files
- `tasks/{nextcloud,monitoring,ha,vwsfriend,git,backup}.yml`: Stack-specific setup tasks
- `templates/`: Jinja2 templates for docker-compose files and service configurations
- `files/`: Static configuration files (Nextcloud PHP/Apache configs)

## Common Development Commands

### Linting
```bash
ansible-lint
```

### Testing the Role
Apply the role using an Ansible playbook:
```bash
ansible-playbook -i inventory playbook.yml
```

### Manual Stack Deployment
After generating docker-compose files, deploy stacks in this order:

1. Start Traefik first:
```bash
docker compose -f docker-compose-traefik.yml -p traefik up -d
```

2. For Nextcloud, start database and redis before the main container:
```bash
docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nc-db
docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nc-redis
docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nextcloud
```

3. Other stacks can be started normally:
```bash
docker compose -f docker-compose-monitoring.yml -p monitoring up -d
docker compose -f docker-compose-ha.yml -p ha up -d
docker compose -f docker-compose-vwsfriend.yml -p vwsfriend up -d
docker compose -f docker-compose-git.yml -p git up -d
```

## Key Variables

### Required Variables (must be set by user)
- `homestack_uid` / `homestack_gid`: User/group IDs for container processes
- `homestack_traefik_hostingde_api_key`: API key for Let's Encrypt DNS challenge
- `homestack_traefik_base_path`: Path for Traefik configuration files
- `homestack_*_base_path`: Base paths for each stack's data storage
- Database passwords, admin credentials, SMTP settings (see defaults/main.yml for full list)

### Stack Activation
Each stack can be enabled/disabled via `homestack_{stackname}_active` variables (default: true)

### Version Management
Docker image versions are managed via Renovate comments in defaults/main.yml:
```yaml
# renovate: image=traefik
homestack_traefik_version: v3.5.4
```

## Important Notes

- Image version variables follow the format: `homestack_{stack}_{service}_image_version`
- All docker-compose files are generated with mode 0600 (owner read/write only)
- The role creates backups of existing compose files when regenerating them
- Nextcloud requires specific startup order (database → redis → app) on first deployment
- The git/forgejo stack requires Traefik to have the `forgejo-git` entrypoint configured for SSH access on port 2222
- All templates use Jinja2 variable substitution from defaults/main.yml and user vars
