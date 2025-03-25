#!/usr/bin/env bash

# Include common functions and variables
. "$(dirname "$0")/common.sh"

# Set script-specific variables
LOG_FILE="$SCRIPTPATH/backup_all.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/backup_all_status.log}"
CONFIG_DIR="${1:-$SCRIPTPATH/configs}"

# Parse command-line arguments
VERBOSE=false
DRY_RUN=false
while getopts "vd" opt; do
    case $opt in
        v) VERBOSE=true;;
        d) DRY_RUN=true;;
        ?) echo "Usage: $0 [<config_dir>] [-v] [-d]" >&2; exit 1;;
    esac
done

shift $((OPTIND-1))

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Config directory $CONFIG_DIR does not exist!" >&2
    exit 1
fi

if [ ! -f "$SCRIPTPATH/backup.sh" ]; then
    log "ERROR" "backup.sh not found in $SCRIPTPATH!"
    update_status "FAILURE" "backup.sh not found"
    notify "FAILURE" "backup.sh not found in $SCRIPTPATH" "Backup All"
    exit 1
fi

log "INFO" "Starting backup process for all projects in $CONFIG_DIR"
update_status "STARTED" "Backup process for all projects in $CONFIG_DIR"

SUCCESS_COUNT=0
FAILURE_COUNT=0

for config in "$CONFIG_DIR"/*.conf; do
    if [ -f "$config" ]; then
        PROJECT_NAME=$(basename "$config" .conf)
        log "INFO" "Backing up project: $PROJECT_NAME with config $config"

        . "$config"

        BACKUP_CMD="$SCRIPTPATH/backup.sh -c $config -b"
        [ "$VERBOSE" = true ] && BACKUP_CMD="$BACKUP_CMD -v"
        [ "$DRY_RUN" = true ] && BACKUP_CMD="$BACKUP_CMD -d"

        bash -c "$BACKUP_CMD"
        if [ $? -eq 0 ]; then
            log "INFO" "Backup for $PROJECT_NAME completed successfully"
            ((SUCCESS_COUNT++))
        else
            log "ERROR" "Backup for $PROJECT_NAME failed"
            notify "FAILURE" "Backup for $PROJECT_NAME failed" "Backup All"
            ((FAILURE_COUNT++))
        fi
    else
        log "INFO" "No config files found in $CONFIG_DIR"
        update_status "SUCCESS" "No projects to backup"
        notify "SUCCESS" "No projects to backup in $CONFIG_DIR" "Backup All"
        exit 0
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "INFO" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s"
update_status "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s"
notify "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s" "Backup All"

if [ "$FAILURE_COUNT" -gt 0 ]; then
    exit 1
fi