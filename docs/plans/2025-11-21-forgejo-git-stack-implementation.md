# Forgejo Git Stack Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Forgejo self-hosted git stack to ansible-role-docker-compose-homestack with full variable support, health checks, and Traefik integration.

**Architecture:** Single-container Forgejo (rootless) stack with web UI via HTTPS and SSH git operations via TCP routing through Traefik. Follows established patterns for stack isolation, variable management, and conditional activation.

**Tech Stack:** Ansible, Jinja2, Docker Compose, Forgejo (rootless), Traefik

---

## Task 1: Add Default Variables

**Files:**
- Modify: `defaults/main.yml` (after line 96, at the end of file)

**Step 1: Add git stack variables to defaults**

Add these lines after the `homestack_backup_script_path` variable (line 96):

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

**Step 2: Verify syntax with ansible-lint**

Run: `ansible-lint defaults/main.yml`
Expected: No errors related to the new variables

**Step 3: Commit the variables**

```bash
git add defaults/main.yml
git commit -m "Add default variables for git/forgejo stack"
```

---

## Task 2: Fix and Enhance Docker Compose Template

**Files:**
- Modify: `templates/docker-compose-git.yml.j2` (complete file replacement)

**Step 1: Read the current template**

Run: `cat templates/docker-compose-git.yml.j2`
Note: Current bugs on lines 16-17 (wrong service names), missing TCP service definition

**Step 2: Replace entire template with fixed version**

Replace the entire contents of `templates/docker-compose-git.yml.j2` with:

```yaml
{{ ansible_managed | comment }}
---
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
      traefik.enable: true
      traefik.docker.network: traefik-net

      # HTTP/HTTPS for web UI
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

**Key Changes:**
- Line 6: Added image version variable
- Line 7: Added user with uid/gid variables
- Lines 8-13: Added health check
- Line 17: Fixed domain to use variable instead of hardcoded `git.home.weinrich.family`
- Lines 23-26: Fixed router/service names (forgejo-ssh instead of mosquitto)
- Line 26: Added missing TCP service definition
- Line 31: Changed volume path to use variable

**Step 3: Verify template syntax**

Run: `ansible-lint templates/docker-compose-git.yml.j2`
Expected: No syntax errors

**Step 4: Commit the template changes**

```bash
git add templates/docker-compose-git.yml.j2
git commit -m "Fix bugs and enhance docker-compose-git template

- Fix lines 16-17: change mosquitto to forgejo-ssh
- Add missing TCP service definition
- Replace hardcoded values with variables
- Add health check for container monitoring
- Use proper variable substitution for all config"
```

---

## Task 3: Create Git Stack Task File

**Files:**
- Create: `tasks/git.yml`

**Step 1: Create new task file**

Create `tasks/git.yml` with this content:

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

**Step 2: Verify task file syntax**

Run: `ansible-lint tasks/git.yml`
Expected: No errors

**Step 3: Commit the task file**

```bash
git add tasks/git.yml
git commit -m "Add task file for git/forgejo stack

Creates base directory with proper ownership and generates
docker-compose file from template with backup enabled"
```

---

## Task 4: Integrate Git Stack into Main Task Flow

**Files:**
- Modify: `tasks/main.yml` (after line 33)

**Step 1: Read current main.yml structure**

Run: `cat tasks/main.yml | grep -A 2 "Include.*tasks"`
Note: Pattern shows conditional includes with `when:` clauses

**Step 2: Add git stack include**

After line 33 (after the vwsfriend include), add:

```yaml

- name: Include git stack tasks
  ansible.builtin.include_tasks: git.yml
  when: homestack_git_active
```

The file should now have this structure at the end:
```yaml
- name: Include vwsfriend stack tasks
  ansible.builtin.include_tasks: vwsfriend.yml
  when: homestack_vwsfriend_active

- name: Include git stack tasks
  ansible.builtin.include_tasks: git.yml
  when: homestack_git_active

- name: Include backup tasks
  ansible.builtin.include_tasks: backup.yml
  when: homestack_backup
```

**Step 3: Verify main task file**

Run: `ansible-lint tasks/main.yml`
Expected: No errors

**Step 4: Commit the integration**

```bash
git add tasks/main.yml
git commit -m "Integrate git stack into main task flow

Add conditional include for git.yml when homestack_git_active is true"
```

---

## Task 5: Run Full Role Linting

**Files:**
- All modified files

**Step 1: Run ansible-lint on entire role**

Run: `ansible-lint`
Expected: No errors (or only pre-existing warnings unrelated to git stack)

**Step 2: Check git status**

Run: `git status`
Expected: Working tree clean (all changes committed)

**Step 3: Review commit history**

Run: `git log --oneline -5`
Expected: Shows all 4 commits from previous tasks plus design doc commit

---

## Task 6: Documentation Update (Optional)

**Files:**
- Modify: `CLAUDE.md` (if it needs git stack documentation)

**Step 1: Review if CLAUDE.md needs updates**

Check if the CLAUDE.md file should document:
- New `homestack_git_*` variables
- Deployment order for git stack
- Any special configuration notes

**Step 2: Update CLAUDE.md if needed**

Add section under "Stack Components" (around line 16):
```markdown
- **git**: Forgejo self-hosted git service with SSH and web UI access
```

Add section under "Key Variables" documenting the new variables if deemed necessary.

**Step 3: Commit documentation changes (if made)**

```bash
git add CLAUDE.md
git commit -m "Document git/forgejo stack in CLAUDE.md"
```

---

## Verification Steps

After implementation, verify the role works correctly:

1. **Syntax Check:**
   ```bash
   ansible-lint
   ```

2. **Variable Reference Check:**
   Ensure all variables used in templates are defined in defaults:
   ```bash
   grep -o 'homestack_git_[a-z_]*' templates/docker-compose-git.yml.j2 | sort -u
   grep -o 'homestack_git_[a-z_]*' defaults/main.yml | sort -u
   ```
   Both commands should show the same variable names.

3. **Template Rendering Test (if test environment available):**
   Create a test playbook and render the template to verify no Jinja2 errors.

4. **Integration Test (if test environment available):**
   Run the role against a test inventory to ensure the compose file is generated correctly.

---

## Success Criteria

- [ ] All 4 files modified/created (defaults/main.yml, templates/docker-compose-git.yml.j2, tasks/git.yml, tasks/main.yml)
- [ ] ansible-lint passes with no new errors
- [ ] All changes committed with descriptive messages
- [ ] Variables follow naming conventions of other stacks
- [ ] Template fixes all identified bugs (lines 16-17, missing service def)
- [ ] Task file follows patterns from other stack task files
- [ ] Git stack conditionally included in main task flow

---

## Notes for Engineer

**Ansible Role Patterns:**
- This role uses Jinja2 templating with `{{ variable }}` syntax
- All stack-specific variables follow pattern: `homestack_{stackname}_{component}_{property}`
- Task files use `ansible.builtin.*` module syntax
- Conditional includes use `when:` clauses with boolean variables
- File modes: 0600 for generated compose files, 0750 for data directories

**Testing Approach:**
Since this is infrastructure-as-code with Ansible:
- Primary testing is ansible-lint for syntax/best practices
- Secondary testing is actual execution against test environment (if available)
- No traditional unit tests for Ansible roles

**Traefik Requirements:**
The generated docker-compose file assumes Traefik is already configured with a `forgejo-git` entrypoint on the port specified by `homestack_git_ssh_port`. Users must configure this separately in their Traefik static config.

**Forgejo Configuration:**
Forgejo will auto-configure on first startup. No pre-created config files needed - just ensure the data directory exists with correct ownership (handled by tasks/git.yml).
