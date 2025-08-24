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

readonly BACKUP_DIR="$VWSFRIEND_DIR/backup"
readonly MIN_DISK_SPACE_MB=50

readonly LOG_FILE="/var/log/autorestic_backup.log"

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to write log messages and send notifications
log_message() {
    local valid_priorities=(min low default high urgent)
    local priority="default"
    if [[ -n "${2-}" ]]; then
        for valid_priority in "${valid_priorities[@]}"; do
            if [[ "$valid_priority" == "$2" ]]; then
                priority="$2"
                break
            fi
        done
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$priority] $1" | tee -a "$LOG_FILE"
    if [[ -n "${NTFY_TOPIC-}" ]]; then
        curl -H "X-Priority: ${priority}" -d "$1" "$NTFY_TOPIC"
    fi
}

# Function to check if a container is running
check_container() {
    local container_name="$1"
    if ! docker ps --filter "name=^/${container_name}$" | grep -q "$container_name"; then
        log_message "Container '$container_name' is not running" high
        return 1
    fi
    return 0
}

# Function to check available disk space
check_disk_space() {
    local available_space_mb
    available_space_mb=$(df --output=avail -m "$BACKUP_DIR" | tail -n 1 | tr -d '[:space:]')
    if [ "$available_space_mb" -lt "$MIN_DISK_SPACE_MB" ]; then
        log_message "Insufficient disk space in $BACKUP_DIR. Available: ${available_space_mb}MB, Required: ${MIN_DISK_SPACE_MB}MB" "urgent"
        exit 1
    fi
}

# Cleanup function to run on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_message "An error occurred during backup (exit code: $exit_code)" high
    fi
    exit $exit_code
}

trap cleanup EXIT

before() {
    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"

    # Check containers are running
    check_container "$DB_CONTAINER" || exit 1
    check_container "$VWSFRIEND_CONTAINER" || exit 1
    check_container "$GRAFANA_CONTAINER" || exit 1

    # Check disk space
    check_disk_space

    log_message "Creating backup of vwsfriend database" low
    currentDate=$(date '+%Y%m%d-%H%M%S')
    backupFile="$BACKUP_DIR/vwsfriend-db-${currentDate}.dump.gz"
    PGPASSWORD="$DB_PASSWORD" docker exec "$DB_CONTAINER" pg_dump --compress=9 --format=c -U "$DB_USER" -d "$DB_NAME" | gzip -c > "$backupFile"
    log_message "Database backup created" low

    log_message "Creating ZFS snapshots of vwsfriend config and grafana data" low
    /usr/sbin/zfs destroy "$ZPOOL_VWSFRIEND/vwsfriend@restic" 2>/dev/null || true
    if ! (/usr/sbin/zfs snapshot "$ZPOOL_VWSFRIEND/vwsfriend@${currentDate}" && \
            /usr/sbin/zfs snapshot "$ZPOOL_VWSFRIEND/vwsfriend@restic"); then
        log_message "Failed to create ZFS snapshots" high
        exit 1
    fi

    # TODO: Cleanup old snapshots

    log_message "Local vwsfriend backup successful" low
}

success() {
    log_message "Remove backup of vwsfriend database" low
    if ! rm -rf "${BACKUP_DIR:?}"; then
        log_message "Failed to remove database backup" high
        exit 1
    fi
    log_message "Database backup removed" low

    curl -H "X-Priority: default" \
        -H "X-Title: Backup of vwsfriend data to ${AUTORESTIC_LOCATION} successful" \
        -H "X-Tags: white_check_mark" \
        -H "Markdown: yes" \
        "$NTFY_TOPIC" \
     --data-binary @- << EOF
Files:           ${AUTORESTIC_FILES_ADDED_BACKBLAZE} new,     ${AUTORESTIC_FILES_CHANGED_BACKBLAZE} changed,    ${AUTORESTIC_FILES_UNMODIFIED_BACKBLAZE} unmodified
Dirs:            ${AUTORESTIC_DIRS_ADDED_BACKBLAZE} new,    ${AUTORESTIC_DIRS_CHANGED_BACKBLAZE} changed,     ${AUTORESTIC_DIRS_UNMODIFIED_BACKBLAZE} unmodified
Added to the repository: ${AUTORESTIC_ADDED_SIZE_BACKBLAZE}

processed ${AUTORESTIC_PROCESSED_FILES_BACKBLAZE} files, ${AUTORESTIC_PROCESSED_SIZE_BACKBLAZE} in ${AUTORESTIC_PROCESSED_DURATION_BACKBLAZE}
EOF
}

failure() {
    log_message "Backup of vwsfriend data to ${AUTORESTIC_LOCATION} failed" high
}

restore() {
    # Check containers are running
    check_container "$DB_CONTAINER" || exit 1

    if check_container "$VWSFRIEND_CONTAINER"; then
        log_message "Stopping vwsfriend container" low
        docker stop "$VWSFRIEND_CONTAINER"
    fi
    if check_container "$GRAFANA_CONTAINER"; then
        log_message "Stopping grafana container" low
        docker stop "$GRAFANA_CONTAINER"
    fi

    # Restore restic snapshot
    if ! autorestic restore --location vwsfriend --from backblaze --to "$VWSFRIEND_DIR/" latest:"$VWSFRIEND_DIR/.zfs/snapshot/restic"; then
        log_message "Failed to restore restic snapshot" high
        exit 1
    fi

    # Restore DB backup
    if [ ! -d "$BACKUP_DIR/" ] || [ -z "$(ls -A "$BACKUP_DIR/")" ]; then
        log_message "No database backup files found" high
        exit 1
    fi
    backupFile=$(find "$BACKUP_DIR/" -type f -name "*.dump.gz" | sort | tail -n 1)
    if [ -z "$backupFile" ] || [ ! -f "$backupFile" ]; then
        log_message "Could not find a valid backup file" high
        exit 1
    fi
    gunzip -c "$backupFile" | PGPASSWORD="$DB_PASSWORD" docker exec -i "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME"
    log_message "Database restore completed for $DB_CONTAINER" low

    # Start containers
    echo "Starting containers..."
    docker start "$VWSFRIEND_CONTAINER"
    docker start "$GRAFANA_CONTAINER"
    log_message "Restore successful" default
    echo
    echo "Restore successful."
    echo
}

# Check if the script is being run as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        before)
            before
            ;;
        success)
            success
            ;;
        failure)
            failure
            ;;
        restore)
            restore
            ;;
        *)
            echo "Usage: $0 {before|success|failure|restore}"
            exit 0
            ;;
    esac
fi
