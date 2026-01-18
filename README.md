# docker-compose-homestack

This role is an opinionated approach to automating the creation of docker-compose files to run the software on my home
server.

## Why?

Started as a fork of the
[docker-compose-generator](https://github.com/ironicbadger/ansible-role-docker-compose-generator), this now works
differently. I just didn't find it very useful to have almost all the values and settings in the vars file and then have
a role that uses a template to simply transform it into its final state. It also didn't support using different networks
to segment the different stacks. So I decided to rewrite my original fork.

## Stack setup

All connections to all containers are proxied through traefik. This allows everything to be offered using TLS with
automatically generated Let's Encrypt certificates. To improve security and further isolate the containers, each stack
sits on its own network. Only the container that is the entrypoint or the frontend of the software is able to talk to
traefik and vice versa, all others are only able to communicate within their network.

![alt text](docs/stack.png)

## The stacks

### traefik

_traefik_ lives in the `traefik` network. This network also contains the _error-pages_ container that offers generic
error pages in case some service is not available.

### Nextcloud

Nextcloud needs a database, a redis and some other containers that make Nextcloud work.

During the first start, the database must be started first so it can be initialized. Only then start the nextcloud
container. Otherwise the installation somehow breaks.

```sh
% docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nc-db
[+] Running 2/2
 ✔ Network nextcloud-net  Created                                           0.1s
 ✔ Container nc-db        Started                                           1.0s
docker@memoryalpha ~/home-stack
 % docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nc-redis
[+] Running 1/1
 ✔ Container nc-redis     Started                                           1.1s
docker@memoryalpha ~/home-stack
 % docker compose -f docker-compose-nextcloud.yml -p nextcloud up -d nextcloud
[+] Running 3/3
 ✔ Container nc-redis   Healthy                                             0.9s
 ✔ Container nc-db      Healthy                                             0.9s
 ✔ Container nextcloud  Started
 ```

## Breaking Changes

### Version 2.0.0 (PR #184 - Add Forgejo git stack)

**Traefik configuration is now managed by Ansible**

Starting with this version, Ansible automatically generates and manages the Traefik configuration files (`traefik.yml` and `config.yml`) in the `homestack_traefik_base_path` directory. Previously, users were responsible for manually creating and maintaining these files.

**Impact:**

- Any existing custom Traefik configuration files will be overwritten by the templated versions
- Backups are automatically created before overwriting (using `backup: true`)
- Users with custom Traefik settings beyond Docker labels will need to migrate their configurations

**Migration steps:**

1. Review your current `traefik.yml` and `config.yml` files before running this version
2. Check the generated templates in `templates/traefik.yml.j2` and `templates/config.yml.j2`
3. If you have custom settings, consider using the template variables or manually merging after deployment
4. Backups will be stored with a timestamp suffix (e.g., `traefik.yml.2026-01-18@12:00:00~`)

## Variables

### Global variables

| Variable                | default   | Description |
| ----------------------- | --------- | ----------- |
| `homestack_output_path` | `"~"`     | Where to put the rendered docker-compose files |
| `homestack_uid`         | _not set_ | The user ID used for running docker images to not run as root |
| `homestack_gid`         | _not set_ | The group ID used for running docker images to not run as root |

### Traefik

| Variable                              | default     | Description |
| ------------------------------------- | ----------- | ----------- |
| `homestack_traefik_version`           | 2.11.3      | version of the traefik docker image |
| `homestack_traefik_hostingde_api_key` | _not set_   | API key to use the hosting.de API for the Let's encrypt DNS challenge |
| `homestack_traefik_base_domain`       | example.com | base domain name, will be prefixed with `traefik.` for the FQDN |
| `homestack_traefik_base_path`         | _not set_   | where are the traefik files stored on disk |
| `homestack_error_pages_version`       | 2.27        | version of the errorpages docker image |
| `homestack_error_pages_theme`         | app-down    | the theme used by errorpages |

### Variables for the Nextcloud stack

| Variable                                  | default                   | Description |
| ----------------------------------------- | ------------------------- | ----------- |
| `homestack_nextcloud_active`              | `true`                    | Switch rendering of nextcloud docker-compose file on or off |
| `homestack_nextcloud_uid`                 | `"1000"`                  | The UID used for the nextcloud container |
| `homestack_nextcloud_gid`                 | `"1000"`                  | The GID used for the nextcloud container |
| `homestack_nextcloud_image_version`       | `nextcloud:29.0.7-apache` | version of the nextcloud docker image |
| `homestack_nextcloud_base_path`           | _not set_                 | where are the nextcloud files stored on disk |
| `homestack_nextcloud_admin_user`          | `admin`                   | username of the nextcloud admin user |
| `homestack_nextcloud_admin_password`      | `5UP3r53Cr37P455W0rD`     | password of the nextcloud admin user |
| `homestack_nextcloud_base_domain`         | `example.com`             | base domain name, will be prefixed with `nextcloud.` for the FQDN |
| `homestack_nextcloud_smtp_host`           | _not set_                 | the host used to send nextlcoud notification emails |
| `homestack_nextcloud_smtp_name`           | _not set_                 | username to authenticate at the SMTP host |
| `homestack_nextcloud_smtp_password`       | _not set_                 | password to authenticate at the SMTP host |
| `homestack_nextcloud_mysql_path`          | _not set_                 | where are the nextcloud db files stored on disk |
| `homestack_nextcloud_mysql_password`      | `password`                | password for the nextcloud mysql DB |
| `homestack_nextcloud_mysql_root_password` | `5UP3r53Cr37P455W0rD`     | password of the mysql root user |

### Variables for the monitoring stack

### Variables for the home automation stack

| Variable                                  | default             | Description |
| ----------------------------------------- | ------------------- | ----------- |
| `homestack_ha_active`                     | `true`              | Switch rendering of home automation docker-compose file on or off |
| `homestack_ha_base_domain`                | `example.com`       | base domain name, will be prefixed with a name for the respective service for the FQDN |
| `homestack_ha_mosquitto_image_version`    | `2.0.20`            | version of the eclipse-mosquitto image |
| `homestack_ha_mosquitto_base_path`        | _not set_           | path for storing the mosquitto data on disk |
| `homestack_ha_mosquitto_users`            | `{}`                | list of users to setup for mosquitto, passwords must already be encoded using `mosquitto_passwd` |
| `homestack_ha_evcc_image_version`         | `0.133.0`           | version of the evcc image |
| `homestack_ha_evcc_base_path`             | _not set_           | path for storing the evcc data on disk |
| `homestack_ha_evcc_installation_id`       | _not set_           | unique ID of the installation (see evcc documentation) |
| `homestack_ha_evcc_mqtt_user`             | `evcc`              | user used to connect to the mqtt broker |
| `homestack_ha_evcc_mqtt_password`         | `password`          | password used to connect to the mqtt broker |
| `homestack_ha_evcc_vw_user`               | `mail@example.com`  | email for accessing the We Connect services |
| `homestack_ha_evcc_vw_password`           | `supersafe`         | password for accessing the We Connect services |
| `homestack_ha_evcc_vw_vin`                | `WVWZZZAAZJD000000` | VIN for accessing the We Connect services |

### Variables for the git stack (Forgejo)

| Variable                                  | default                   | Description |
| ----------------------------------------- | ------------------------- | ----------- |
| `homestack_git_active`                    | `true`                    | Switch rendering of git docker-compose file on or off |
| `homestack_git_base_domain`               | `example.com`             | base domain name, will be prefixed with `git.` for the FQDN |
| `homestack_git_ssh_port`                  | `2222`                    | External SSH port shown in git clone URLs (Traefik routes to internal container port 2222) |
| `homestack_git_forgejo_image_version`     | `11-rootless`             | version of the Forgejo docker image |
| `homestack_git_base_path`                 | _not set_                 | Base directory for Forgejo data (repositories, config, logs). Example: /opt/forgejo |
| `homestack_git_root_url`                  | `https://git.{{ homestack_git_base_domain }}/` | Full URL for accessing Forgejo web interface |
| `homestack_git_ssh_domain`                | `git.{{ homestack_git_base_domain }}` | Domain shown in SSH clone URLs |
| `homestack_git_db_type`                   | `sqlite3`                 | Database type: `sqlite3`, `mysql`, or `postgres` |
| `homestack_git_db_path`                   | `/var/lib/gitea/data/forgejo.db` | Path to SQLite database file (only used when db_type is sqlite3) |
| `homestack_git_db_host`                   | _not set_                 | Database host:port (required for MySQL/PostgreSQL). Example: `127.0.0.1:3306` |
| `homestack_git_db_name`                   | _not set_                 | Database name (required for MySQL/PostgreSQL) |
| `homestack_git_db_user`                   | _not set_                 | Database user (required for MySQL/PostgreSQL) |
| `homestack_git_db_password`               | _not set_                 | Database password (required for MySQL/PostgreSQL) |
| `homestack_git_secret_key`                | _not set_                 | Encryption key for cookies and tokens. Generate with: `openssl rand -hex 32` |
| `homestack_git_internal_token`            | _not set_                 | Authentication token for internal API calls. Generate with: `openssl rand -hex 105` |
| `homestack_git_lfs_jwt_secret`            | _not set_                 | JWT secret for LFS (defaults to secret_key if not set) |
| `homestack_git_oauth2_jwt_secret`         | _not set_                 | JWT secret for OAuth2 (defaults to secret_key if not set) |
| `homestack_git_disable_registration`      | `true`                    | Disable public user registration |
| `homestack_git_require_signin_view`       | `false`                   | Require authentication to view any page |
| `homestack_git_webhook_allowed_hosts`     | `external`                | Restrict webhooks to external hosts (not internal networks). Use `*` to allow all (not recommended) |
| `homestack_git_mailer_enabled`            | `false`                   | Enable email notifications |
| `homestack_git_mailer_host`               | _not set_                 | SMTP server hostname (required if mailer is enabled) |
| `homestack_git_mailer_port`               | `587`                     | SMTP port (587 for STARTTLS, 465 for SMTPS, 25 for plain) |
| `homestack_git_mailer_from`               | _not set_                 | Email address used as sender (required if mailer is enabled) |
| `homestack_git_mailer_user`               | _not set_                 | Username for SMTP authentication (optional) |
| `homestack_git_mailer_password`           | _not set_                 | Password for SMTP authentication (optional) |
