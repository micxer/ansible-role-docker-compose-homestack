#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/forgejo_env_vars.sh" ]; then
    source "$SCRIPT_DIR/forgejo_env_vars.sh"
else
    echo "Environment variables file 'forgejo_env_vars.sh' not found in $SCRIPT_DIR"
    exit 1
fi

readonly FORGEJO_CONTAINER="forgejo"
readonly LOG_FILE="/var/log/autorestic_backup.log"

set -euo pipefail

FORGEJO_WAS_RUNNING=0
FORGEJO_STOPPED=0

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

container_is_running() {
    docker ps --filter "name=^/${FORGEJO_CONTAINER}$" --format '{{.Names}}' |
        grep -Fxq "$FORGEJO_CONTAINER"
}

cleanup() {
    local exit_code=$?
    if [ "$FORGEJO_STOPPED" -eq 1 ] && [ "$FORGEJO_WAS_RUNNING" -eq 1 ]; then
        if docker start "$FORGEJO_CONTAINER"; then
            FORGEJO_STOPPED=0
            log_message "Forgejo container restarted during cleanup" low
        else
            log_message "Failed to start Forgejo container" high
            exit_code=1
        fi
    fi

    if [ "$exit_code" -ne 0 ]; then
        log_message "An error occurred during Forgejo backup or restore (exit code: $exit_code)" high
    fi

    exit "$exit_code"
}

trap cleanup EXIT

before() {
    if ! container_is_running; then
        log_message "Container '$FORGEJO_CONTAINER' is not running" high
        exit 1
    fi

    FORGEJO_WAS_RUNNING=1
    log_message "Stopping Forgejo container" low
    if ! docker stop "$FORGEJO_CONTAINER"; then
        log_message "Failed to stop Forgejo container" high
        exit 1
    fi
    FORGEJO_STOPPED=1

    log_message "Creating ZFS snapshots of Forgejo data" low
    /usr/sbin/zfs destroy "$ZPOOL_FORGEJO/forgejo@restic" 2>/dev/null || true
    local current_date
    current_date=$(date '+%Y%m%d-%H%M%S')
    if ! (
        /usr/sbin/zfs snapshot "$ZPOOL_FORGEJO/forgejo@${current_date}" &&
        /usr/sbin/zfs snapshot "$ZPOOL_FORGEJO/forgejo@restic"
    ); then
        log_message "Failed to create Forgejo ZFS snapshots" high
        exit 1
    fi

    log_message "Starting Forgejo container" low
    if ! docker start "$FORGEJO_CONTAINER"; then
        log_message "Failed to start Forgejo container" high
        exit 1
    fi
    FORGEJO_STOPPED=0
    log_message "Local Forgejo backup snapshot created" low
}

success() {
    curl -H "X-Priority: default" \
        -H "X-Title: Backup of Forgejo data to ${AUTORESTIC_LOCATION} successful" \
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
    log_message "Backup of Forgejo data to ${AUTORESTIC_LOCATION} failed" high
}

restore() {
    if container_is_running; then
        FORGEJO_WAS_RUNNING=1
        log_message "Stopping Forgejo container" low
        if ! docker stop "$FORGEJO_CONTAINER"; then
            log_message "Failed to stop Forgejo container" high
            exit 1
        fi
        FORGEJO_STOPPED=1
    fi

    if ! autorestic restore --location forgejo --from backblaze --to "$FORGEJO_DIR/" \
        latest:"$FORGEJO_DIR/.zfs/snapshot/restic"; then
        log_message "Failed to restore Forgejo snapshot" high
        exit 1
    fi

    if [ "$FORGEJO_STOPPED" -eq 1 ]; then
        log_message "Starting Forgejo container" low
        if ! docker start "$FORGEJO_CONTAINER"; then
            log_message "Failed to start Forgejo container" high
            exit 1
        fi
        FORGEJO_STOPPED=0
    fi

    log_message "Restore successful" low
}

# Check if the script is being run as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check the first argument to determine the action
    case "${1-}" in
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
