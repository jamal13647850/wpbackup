#!/usr/bin/env bash

. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/remove_old.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/remove_old_status.log}"

DRY_RUN=false
VERBOSE=false
while getopts "c:dv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-d] [-v]" >&2; exit 1;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file not specified! Use -c <config_file>" >&2
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE not found!" >&2
    exit 1
else
    . "$CONFIG_FILE"
fi

for var in fullPath BACKUP_RETAIN_DURATION; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"

cleanup_remove() {
    cleanup "Old backups removal process" "Remove Old"
}
trap cleanup_remove INT TERM

log "INFO" "Starting removal of old backups in $fullPath older than $BACKUP_RETAIN_DURATION days"
update_status "STARTED" "Removal of old backups in $fullPath"

if [ "$DRY_RUN" = false ]; then
    find "$fullPath" -type f -mtime +"$BACKUP_RETAIN_DURATION" -exec rm -v {} \;
    check_status $? "Removing old backups" "Remove Old"
else
    log "INFO" "Dry run: Listing files that would be removed"
    find "$fullPath" -type f -mtime +"$BACKUP_RETAIN_DURATION" -ls
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Old backups removal process completed successfully in ${DURATION}s"
update_status "SUCCESS" "Old backups removal process in ${DURATION}s"
notify "SUCCESS" "Old backups removal process completed successfully in ${DURATION}s" "Remove Old"