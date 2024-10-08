#!/bin/sh

set -eu

# FIXME: cron jobs are hardcoded for `www-data` user
# https://github.com/nextcloud/docker/issues/1740
#
# Apache may not run under `www-data` in non-root containers,
# which leads to permission errors in cron jobs.
#
# We create a user with the UID under which apache is running,
# and then move the cron job from `www-data` to that user.

UID_USER="$(getent passwd $UID | cut -d: -f1)"

if [ -z "$UID_USER" ]; then
  UID_USER=user
  adduser --disabled-password \
          --gecos "" \
          --uid "$UID" \
          $UID_USER
fi

if ! [ -f "/crontabs/$UID_USER" ]; then
  mkdir /crontabs || true
  cp /var/spool/cron/crontabs/www-data \
     /crontabs/$UID_USER
  # NOTE: crontab must be "own"ed by root,
  # but we make it g+w to allow a non-root host user to edit it.
  chown "root:$GID" /crontabs/$UID_USER
  chmod g+w /crontabs/$UID_USER
fi

exec busybox crond -f -l 0 \
                   -L /dev/stdout \
                   -c /crontabs
