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

## Variables

### Global variables

| Variable                | default | Description |
| ----------------------- | ------- | ----------- |
| `homestack_output_path` | `"~"`   | Where to put the rendered docker-compose files |

### Traefik

| Variable                              | default     | Description |
| ------------------------------------- | ----------- | ----------- |
| `homestack_traefik_version`           | 2.11.3      | version of the traefik docker image |
| `homestack_traefik_hostingde_api_key` | _not set_   | API key to use the hosting.de API for the Let's encrypt DNS challenge |
| `homestack_traefik_base_domain`       | example.com | base domain name, will be prefixed with `traefik.` for the FQDN |
| `homestack_traefik_base_path`         | _not set_   | where are the traefik files stored on disk |
| `homestack_error_pages_version`       | 2.27        | version of the errorpages docker image |
| `homestack_error_pages_theme`         | matrix      | the theme used by errorpages |

### Variables for Nextcloud

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
