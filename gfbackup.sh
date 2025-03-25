#!/usr/bin/env bash

. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/gfbackup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/gfbackup_status.log}"

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
FORM_FILE_PREFIX="${FORM_FILE_PREFIX:-Forms}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"  # Dynamic format support
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
FORM_FILENAME="${FORM_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"

validate_ssh() {
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
    check_status $? "SSH connection validation" "Forms Backup"
}

cleanup_forms() {
    cleanup "Forms backup process" "Forms Backup"
    rm -rf "$DEST"
}
trap cleanup_forms INT TERM

log "INFO" "Starting forms backup process for $DIR"
update_status "STARTED" "Forms backup process for $DIR"

validate_ssh
log "INFO" "SSH connection validated successfully"

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR"
    check_status $? "Creating backups directory" "Forms Backup"
    mkdir -pv "$DEST"
    check_status $? "Creating destination directory" "Forms Backup"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/Forms"
    check_status $? "Creating Forms directory" "Forms Backup"
    cd "$DEST/Forms"
    if wp plugin is-installed gravityforms --path="$wpPath" >/dev/null 2>&1; then
        nice -n "$NICE_LEVEL" wp gf export --path="$wpPath" --all --dir="$DEST/Forms"
        check_status $? "Exporting Gravity Forms" "Forms Backup"
    else
        log "ERROR" "Gravity Forms plugin is not installed in $wpPath"
        report_error 1 "Gravity Forms plugin not found" "Forms Backup"
    fi
    cd "$DEST"
    log "DEBUG" "Starting forms compression"
    compress "Forms/" "$FORM_FILENAME"
    check_status $? "Forms compression" "Forms Backup"
    nice -n "$NICE_LEVEL" rm -rfv Forms/
    check_status $? "Cleaning up Forms directory" "Forms Backup"
    nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FORM_FILENAME" -e "ssh -p ${destinationPort} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
    check_status $? "Uploading forms backup" "Forms Backup"
else
    log "INFO" "Dry run: Skipping forms backup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Forms backup process for $DIR completed successfully in ${DURATION}s"
update_status "SUCCESS" "Forms backup process for $DIR in ${DURATION}s"
notify "SUCCESS" "Forms backup process for $DIR completed successfully in ${DURATION}s" "Forms Backup"