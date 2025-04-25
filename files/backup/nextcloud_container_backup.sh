#!/bin/bash

# Source the environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/nextcloud_env_vars.sh" ]; then
    source "$SCRIPT_DIR/nextcloud_env_vars.sh"
else
    echo "Environment variables file 'nextcloud_env_vars.sh' not found in $SCRIPT_DIR"
    exit 1
fi

readonly NC_CONTAINER="nextcloud"
readonly DB_CONTAINER="nc-db"

readonly BACKUP_DIR="$NEXTCLOUD_DIR/db-backup"
readonly MIN_DISK_SPACE_MB=100

readonly LOG_FILE="/var/log/autorestic_backup.log"

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Function to write log messages
log_message() {
    local valid_priorities=(min low default high urgent)
    local priority="default"

    # Validate the second parameter
    if [[ -n "${2-}" ]]; then
        for valid_priority in "${valid_priorities[@]}"; do
            if [[ "$valid_priority" == "$2" ]]; then
                priority="$2"
                break
            fi
        done
    fi

    echo "$(date +"%Y-%m-%d %H:%M:%S") $1" | tee -a "$LOG_FILE"
    curl -H "X-Priority: ${priority}" -d "$1" "$NTFY_TOPIC"
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

# Function to disable maintenance mode and exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_message "An error occurred during backup (exit code: $exit_code)" high
    fi
    
    log_message "Disabling maintenance mode for Nextcloud" low
    if ! docker exec -u "$NEXTCLOUD_UID" nextcloud php occ maintenance:mode --off; then
        log_message "Failed to disable maintenance mode on cleanup" high
    fi

    # Clean up temporary files
    if [ -f "$MYSQL_CNF" ]; then
        docker exec nc-db rm -f /tmp/backup.cnf
        rm -f "$MYSQL_CNF"
    fi
    
    exit $exit_code
}

# Register the cleanup function to run on script exit
trap cleanup EXIT

before() {
    # check that containers are running
    check_container "$DB_CONTAINER" || exit 1
    check_container "$NC_CONTAINER" || exit 1

    # Set maintenance mode
    log_message "Enabling maintenance mode for Nextcloud" low
    if ! docker exec -u "$NEXTCLOUD_UID" nextcloud php occ maintenance:mode --on
    then
        log_message "Failed to enable maintenance mode" high
        exit 1
    fi

    log_message "Creating backup of Nextcloud database" low

    # Create backup directory
    if ! mkdir -p "$BACKUP_DIR"
    then
        log_message "Failed to create backup directory" high
        exit 1
    fi

    # Check available disk space before backup
    available_space_mb=$(df -m "$NEXTCLOUD_DIR" | awk 'NR==2 {print $4}')

    if [ "$available_space_mb" -lt "$MIN_DISK_SPACE_MB" ]; then
        log_message "Insufficient disk space for backup: ${available_space_mb}MB available, ${MIN_DISK_SPACE_MB}MB required" high
        exit 1
    fi

    # Create gzipped DB backup
    currentDate=$(date +"%Y%m%d-%H%M%S")
    backupFile="$BACKUP_DIR/nextcloud-db-${currentDate}.sql.gz"

    # Create temporary MySQL config file
    MYSQL_CNF=$(mktemp)
    cat > "$MYSQL_CNF" << EOF
[client]
user=root
password='$MYSQL_ROOT_PASSWORD'
EOF
    chmod 600 "$MYSQL_CNF"

    # Copy config into container
    docker cp "$MYSQL_CNF" nc-db:/tmp/backup.cnf

    if ! docker exec "nc-db" /usr/bin/mariadb-dump --defaults-extra-file=/tmp/backup.cnf \
        --single-transaction --default-character-set=utf8mb4 "nextcloud" | gzip -c > "${backupFile}"; then
        docker exec nc-db rm -f /tmp/backup.cnf
        rm -f "$MYSQL_CNF"
        log_message "Failed to create backup" high
        exit 1
    fi

    log_message "Database backup created" low

    log_message "Creating ZFS snapshots of Nextcloud data" low
    /usr/sbin/zfs destroy "$ZPOOL_NC/nextcloud@restic" 2>/dev/null || true
    if ! (/usr/sbin/zfs snapshot "$ZPOOL_NC/nextcloud@${currentDate}" && 
            /usr/sbin/zfs snapshot "$ZPOOL_NC/nextcloud@restic"); then
        log_message "Failed to create ZFS snapshots" high
        exit 1
    fi

    # TODO: Cleanup old snapshots

    log_message "Local Nextcloud backup successful" low
}

success() {
    log_message "Remove backup of Nextcloud database" low
    if ! rm -r "$BACKUP_DIR"
    then
        log_message "Failed to database backup" high
        exit 1
    fi

    log_message "Database backup removed" low

    curl -H "X-Priority: default" \
        -H "X-Title: Backup of Nextcloud data to ${AUTORESTIC_LOCATION} successful" \
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
    log_message "Backup of Nextcloud data to ${AUTORESTIC_LOCATION} failed" high
}

restore() {
    # check that containers are running
    check_container "$DB_CONTAINER" || exit 1

    if check_container "$NC_CONTAINER"; then
        log_message "Stopping Nextcloud container" low
        docker stop nextcloud
    fi

    # Restore restic snapshot
    if ! autorestic restore --location nextcloud --from backblaze --to "$NEXTCLOUD_DIR/" latest:"$NEXTCLOUD_DIR/.zfs/snapshot/restic"
    then
        log_message "Failed to restore restic snapshot" high
        exit 1
    fi

    # Check if backup folder exists and contains files
    if [ ! -d "$BACKUP_DIR/" ] || [ -z "$(ls -A "$BACKUP_DIR/")" ]; then
        log_message "No database backup files found" high
        exit 1
    fi

    # Look for first file in folder "$BACKUP_DIR/"
    backupFile=$(find "$BACKUP_DIR/" -type f -printf "%T@ %p\n" | sort -n | tail -n 1 | awk '{print $2}')

    # Validate backup file after finding it
    if [ -z "$backupFile" ] || [ ! -f "$backupFile" ]; then
        log_message "Could not find a valid backup file" high
        exit 1
    fi

    # Restore DB backup
    if ! (gunzip < "$backupFile" | docker exec -i "nc-db" /usr/bin/mariadb -u "root" -p"$MYSQL_ROOT_PASSWORD" "nextcloud")
    then
        log_message "Failed to restore DB backup" high
        exit 1
    fi

    # Only remove backup files after confirming restoration success
    # Test DB connection first
    if docker exec "nc-db" /usr/bin/mariadb -u "root" -p"$MYSQL_ROOT_PASSWORD" -e "SHOW TABLES" nextcloud > /dev/null; then
        log_message "Database restore verification successful" low
        rm "$backupFile"
        rmdir "$BACKUP_DIR"
    else
        log_message "Database restore verification failed - keeping backup files" high
        exit 1
    fi

    log_message "Restore successful" default
    echo
    echo "Restore successful. To activate the nextcloud container (if it was running before), run the following command:"
    echo "docker start nextcloud"
    echo
    echo "After activating the nextcloud container, you have to deactivate the maintenance mode manually:"
    echo "docker exec -u $NEXTCLOUD_UID nextcloud php occ maintenance:mode --off"
    echo
    echo "If you have restored from scratch, you have to update the .htaccess file manually:"
    echo "docker exec -u $NEXTCLOUD_UID nextcloud php occ maintenance:update:htaccess"
    echo

}

# Check if the script is being run as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check the first argument to determine the action
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
            exit 1
            ;;
    esac
fi