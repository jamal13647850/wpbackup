#!/usr/bin/env bash

. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/database.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/database_status.log}"

DRY_RUN=false
VERBOSE=false
while getopts "c:f:dv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;  # Added dynamic format support
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-f <format>] [-d] [-v]" >&2; exit 1;;
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

for var in wpPath destinationPort destinationUser destinationIP destinationDbBackupPath privateKeyPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
DEST="$BACKUP_DIR/$DIR"
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"  # Dynamic format support
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
DB_FILENAME="${DB_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"

validate_ssh() {
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
    check_status $? "SSH connection validation" "Database Backup"
}

cleanup_database() {
    cleanup "Database backup process" "Database Backup"
    rm -rf "$DEST"
}
trap cleanup_database INT TERM

log "INFO" "Starting database backup process for $DIR"
update_status "STARTED" "Database backup process for $DIR"

validate_ssh
log "INFO" "SSH connection validated successfully"

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR"
    check_status $? "Creating backups directory" "Database Backup"
    mkdir -pv "$DEST"
    check_status $? "Creating destination directory" "Database Backup"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/DB"
    check_status $? "Creating DB directory" "Database Backup"
    cd "$DEST/DB"
    nice -n "$NICE_LEVEL" wp db export --add-drop-table --path="$wpPath"
    check_status $? "Database export" "Database Backup"
    cd "$DEST"
    log "DEBUG" "Starting database compression"
    compress "DB/" "$DB_FILENAME"
    check_status $? "Database compression" "Database Backup"
    nice -n "$NICE_LEVEL" rm -rfv DB/
    check_status $? "Cleaning up DB directory" "Database Backup"
    nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" -e "ssh -p ${destinationPort} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
    check_status $? "Uploading database backup" "Database Backup"
else
    log "INFO" "Dry run: Skipping database backup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Database backup process for $DIR completed successfully in ${DURATION}s"
update_status "SUCCESS" "Database backup process for $DIR in ${DURATION}s"
notify "SUCCESS" "Database backup process for $DIR completed successfully in ${DURATION}s" "Database Backup"