#!/bin/bash

# Source the environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/vwsfriend_env_vars.sh" ]; then
    source "$SCRIPT_DIR/vwsfriend_env_vars.sh"
else
    echo "Environment variables file 'vwsfriend_env_vars.sh' not found in $SCRIPT_DIR"
    exit 1
fi

readonly VWSFRIEND_CONTAINER="vwsfriend"
readonly DB_CONTAINER="vwsfriend-db"
readonly GRAFANA_CONTAINER="vwsfriend-grafana"

readonly BACKUP_DIR="$VWSFRIEND_DIR/db-backup"
readonly MIN_DISK_SPACE_MB=100

readonly LOG_FILE="/var/log/autorestic_backup.log"

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to write log messages
log_message() {
    local valid_priorities=(min low default high urgent)
    local priority="default"
    if [[ " ${valid_priorities[*]} " == *" $2 "* ]]; then
        priority="$2"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$priority] $1" | tee -a "$LOG_FILE"
}

# Function to check available disk space
check_disk_space() {
    local available_space
    available_space=$(df --output=avail -m "$BACKUP_DIR" | tail -n 1 | tr -d '[:space:]')
    if (( available_space < MIN_DISK_SPACE_MB )); then
        log_message "Insufficient disk space in $BACKUP_DIR. Available: ${available_space}MB, Required: ${MIN_DISK_SPACE_MB}MB" "urgent"
        exit 1
    fi
}

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Check disk space
check_disk_space

# Backup database
log_message "Starting database backup for $DB_CONTAINER" "default"
PGPASSWORD="$DB_PASSWORD" docker exec "$DB_CONTAINER" pg_dump --compress=9 --format=c -U "$DB_USER" -d "$DB_NAME" \
  -f "$BACKUP_DIR/vwsfriend_db_backup_$(date '+%Y%m%d%H%M%S').dump"
log_message "Database backup completed for $DB_CONTAINER" "default"

# Backup container data
log_message "Starting data backup for $VWSFRIEND_CONTAINER" "default"
docker cp "$VWSFRIEND_CONTAINER:/config" "$BACKUP_DIR/config_backup_$(date '+%Y%m%d%H%M%S')"
log_message "Data backup completed for $VWSFRIEND_CONTAINER" "default"

# Backup Grafana data
log_message "Starting data backup for $GRAFANA_CONTAINER" "default"
docker cp "$GRAFANA_CONTAINER:/var/lib/grafana" "$BACKUP_DIR/grafana_backup_$(date '+%Y%m%d%H%M%S')"
log_message "Data backup completed for $GRAFANA_CONTAINER" "default"

log_message "Backup process completed successfully" "default"
