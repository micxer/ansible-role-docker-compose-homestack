#!/bin/bash

# Source the environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/evcc_env_vars.sh" ]; then
    source "$SCRIPT_DIR/evcc_env_vars.sh"
else
    echo "Environment variables file 'evcc_env_vars.sh' not found in $SCRIPT_DIR"
    exit 1
fi

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

# Log before exiting
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_message "An error occurred during backup (exit code: $exit_code)" high
    fi
    
    exit $exit_code
}

# Register the cleanup function to run on script exit
trap cleanup EXIT

before() {
  # Stop evcc container
  log_message "Stopping evcc container" low
  if ! docker stop evcc
  then
      log_message "Failed to stop evcc container" high
      exit 1
  fi

  # Create ZFS snapshot
  log_message "Creating ZFS snapshots of evcc data" low
  /usr/sbin/zfs destroy "$ZPOOL_EVCC/evcc@restic" || true
  currentDate=$(date +"%Y%m%d-%H%M%S")
  if ! (/usr/sbin/zfs snapshot "$ZPOOL_EVCC/evcc@${currentDate}" && 
          /usr/sbin/zfs snapshot "$ZPOOL_EVCC/evcc@restic"); then
      log_message "Failed to create ZFS snapshots" high
      exit 1
  fi

  # Start evcc container
  log_message "Starting evcc container" low
  if ! docker start evcc
  then
      log_message "Failed to start evcc container" high
      exit 1
  fi

  log_message "Local evcc backup snapshot created" low
}

success() {
  curl -H "X-Priority: default" \
      -H "X-Title: Backup of evcc data to ${AUTORESTIC_LOCATION} successful" \
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
  log_message "Backup of evcc data to ${AUTORESTIC_LOCATION} failed" high
}

restore() {
  if ! docker ps --filter name=evcc | grep -q "evcc"
  then
      log_message "Stopping evcc container" low
      docker stop evcc
  fi

  # Restore restic snapshot
  if ! autorestic restore -l evcc --from backblaze --to "$EVCC_DIR/" latest:"$EVCC_DIR/.zfs/snapshot/restic"
  then
      log_message "Failed to restore restic snapshot" high
      exit 1
  fi

  # Start evcc container
  if ! docker start evcc
  then
      log_message "Failed to start evcc container" high
      exit 1
  fi

  log_message "Restore successful" low
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
            exit 0
            ;;
    esac
fi