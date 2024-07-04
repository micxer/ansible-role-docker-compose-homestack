#!/bin/sh
set -eu
# https://github.com/nextcloud/docker/issues/1740#issuecomment-1308141561
adduser --disabled-password --gecos "" --no-create-home --uid "$UID" cron
mv /var/spool/cron/crontabs/www-data /var/spool/cron/crontabs/cron
exec busybox crond -f -L /dev/stdout