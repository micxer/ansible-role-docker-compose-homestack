# Forgejo Git Stack Implementation Design

**Date:** 2025-11-21
**Stack Name:** git (forgejo)
**Approach:** Enhanced implementation with full variable pattern

## Overview

Add a new Forgejo (self-hosted Git service) stack to the ansible-role-docker-compose-homestack, following the established patterns for stack isolation, variable management, and Traefik integration.

## Requirements

1. Fix existing template bugs (lines 16-17 reference wrong service names)
2. Add comprehensive variable support matching other stacks
3. Implement conditional stack activation
4. Add health checks for container monitoring
5. Make SSH port configurable for git operations
6. Follow rootless Forgejo best practices

## Architecture

### Stack Isolation
- Forgejo runs on the `traefik-net` network only (no internal network needed)
- Web UI accessed via HTTPS through Traefik
- SSH git operations via TCP routing through Traefik on configurable port

### Components
- **forgejo**: Rootless Forgejo container (codeberg.org/forgejo/forgejo:11-rootless)
- **Data storage**: Single volume mount at `/var/lib/gitea` (rootless image path)
- **Health monitoring**: HTTP health check at `/api/healthz`

## Implementation Details

### 1. Default Variables (`defaults/main.yml`)

Add the following variables after the vwsfriend section:

```yaml
# git/forgejo
homestack_git_active: true
homestack_git_base_domain: example.com
homestack_git_ssh_port: 2222  # External SSH port for git operations

# renovate: image=codeberg.org/forgejo/forgejo
homestack_git_forgejo_image_version: 11-rootless
# homestack_git_base_path: ""  # must be set
homestack_git_uid: "1000"
homestack_git_gid: "1000"
```

**Key Decisions:**
- `homestack_git_active`: Standard activation pattern
- `homestack_git_ssh_port`: Configurable for Traefik entrypoint (default 2222)
- `homestack_git_uid/gid`: Separate from general homestack_uid (Forgejo recommends 1000:1000)
- Image version follows renovate pattern for automatic updates

### 2. Docker Compose Template (`templates/docker-compose-git.yml.j2`)

**Bug Fixes:**
- Line 16: `traefik.tcp.routers.mosquitto.entrypoints` → `traefik.tcp.routers.forgejo-ssh.entrypoints`
- Line 17: `traefik.tcp.routers.mosquitto.service` → `traefik.tcp.routers.forgejo-ssh.service`

**Enhancements:**
- Replace hardcoded domain with `{{ homestack_git_base_domain }}`
- Replace hardcoded user with `{{ homestack_git_uid }}:{{ homestack_git_gid }}`
- Add image version variable: `{{ homestack_git_forgejo_image_version }}`
- Add health check using curl to `/api/healthz`
- Add missing TCP service definition: `traefik.tcp.services.forgejo-ssh.loadbalancer.server.port: 22`
- Use variable for base path in volume mount

**Template Structure:**
```yaml
services:
  forgejo:
    container_name: forgejo
    image: codeberg.org/forgejo/forgejo:{{ homestack_git_forgejo_image_version }}
    user: "{{ homestack_git_uid }}:{{ homestack_git_gid }}"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    labels:
      # HTTP/HTTPS for web UI
      traefik.enable: true
      traefik.docker.network: traefik-net
      traefik.http.routers.forgejo.rule: Host(`git.{{ homestack_git_base_domain }}`)
      traefik.http.services.forgejo.loadbalancer.server.port: 3000
      traefik.http.routers.forgejo.entrypoints: websecure
      traefik.http.routers.forgejo.tls.options: modern@file

      # TCP for SSH git operations
      traefik.tcp.routers.forgejo-ssh.rule: "HostSNI(`*`)"
      traefik.tcp.routers.forgejo-ssh.entrypoints: forgejo-git
      traefik.tcp.routers.forgejo-ssh.service: forgejo-ssh
      traefik.tcp.services.forgejo-ssh.loadbalancer.server.port: 22
    restart: unless-stopped
    networks:
      - traefik
    volumes:
      - {{ homestack_git_base_path }}:/var/lib/gitea
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro

networks:
  traefik:
    name: traefik-net
    external: true
```

### 3. Task File (`tasks/git.yml`)

Create new file following the pattern from `tasks/ha.yml`:

```yaml
---
- name: git | Ensure forgejo base directory exists
  ansible.builtin.file:
    path: "{{ homestack_git_base_path }}"
    state: directory
    owner: "{{ homestack_git_uid }}"
    group: "{{ homestack_git_gid }}"
    mode: "0750"

- name: git | Write docker-compose file
  ansible.builtin.template:
    src: "docker-compose-git.yml.j2"
    dest: "{{ homestack_output_path }}/docker-compose-git.yml"
    owner: "{{ homestack_uid }}"
    group: "{{ homestack_gid }}"
    mode: "0600"
    backup: true
```

**Notes:**
- Single directory creation (Forgejo auto-configures app.ini)
- Data directory uses git-specific uid/gid
- Compose file uses general homestack uid/gid (consistent with other stacks)
- Backup enabled for compose file changes

### 4. Main Task File Update (`tasks/main.yml`)

Add conditional include after line 33 (after vwsfriend):

```yaml
- name: Include git stack tasks
  ansible.builtin.include_tasks: git.yml
  when: homestack_git_active
```

## Traefik Configuration Requirements

**Note:** This implementation assumes the Traefik configuration already includes:
- An entrypoint named `forgejo-git` on port `{{ homestack_git_ssh_port }}`

Users must add this to their Traefik static configuration:
```yaml
entryPoints:
  forgejo-git:
    address: ":{{ homestack_git_ssh_port }}"
```

## Deployment Order

1. Ensure Traefik is running with forgejo-git entrypoint configured
2. Deploy git stack: `docker compose -f docker-compose-git.yml -p git up -d`
3. Access web UI at `https://git.<domain>` for initial setup
4. Configure SSH URL in Forgejo settings to use port `{{ homestack_git_ssh_port }}`

## Testing

After deployment, verify:
1. Web UI accessible at `https://git.<domain>`
2. Health check passing: `docker inspect forgejo | grep -A 10 Health`
3. SSH port accessible: `ssh -T -p {{ homestack_git_ssh_port }} git@git.<domain>`
4. Data persists after container restart

## Benefits of This Design

1. **Consistency**: Follows exact patterns of existing stacks
2. **Flexibility**: All key values are configurable via variables
3. **Maintainability**: Renovate can auto-update image versions
4. **Monitoring**: Health checks enable container health tracking
5. **Security**: Rootless image, isolated network, TLS via Traefik
6. **Reliability**: Backup of compose files, proper ownership/permissions
