#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/files.log"
STATUS_LOG="$SCRIPTPATH/files_status.log"
LAST_BACKUP_FILE="$SCRIPTPATH/last_backup.txt"
DIR=$(date +"%Y%m%d-%H%M%S")

DRY_RUN=false
VERBOSE=false
INCREMENTAL=false
while getopts "c:f:div" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        i) INCREMENTAL=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-f <format>] [-d] [-i] [-v]" >&2; exit 1;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file not specified! Use -c <config_file>" >&2
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE not found!" >&2
    exit 1
else
    eval "$(load_config "$CONFIG_FILE")"
fi

for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
DEST="$BACKUP_DIR/$DIR"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"
DESTINATION_PATH="${destinationFilesBackupPath:-$BACKUP_DIR}"

EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude '$pattern'"
done

validate_ssh() {
    if [ -n "$destinationIP" ]; then
        ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
        check_status $? "SSH connection validation" "Files Backup"
    fi
}

cleanup_files() {
    cleanup "Files backup process" "Files Backup"
    rm -rf "$DEST"
}
trap cleanup_files INT TERM

log "INFO" "Starting files backup process for $DIR (Incremental: $INCREMENTAL)"
update_status "STARTED" "Files backup process for $DIR"

[ -n "$destinationIP" ] && validate_ssh
log "INFO" "SSH connection validated successfully (if applicable)"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$BACKUP_DIR"
    check_status $? "Creating backups directory" "Files Backup"
    mkdir -p "$DEST"
    check_status $? "Creating destination directory" "Files Backup"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

LAST_BACKUP=""
if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ]; then
    LAST_BACKUP=$(cat "$LAST_BACKUP_FILE")
    log "INFO" "Using last backup for incremental: $LAST_BACKUP"
elif [ "$INCREMENTAL" = true ]; then
    log "WARNING" "No previous backup found, falling back to full backup"
    INCREMENTAL=false
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$DEST/Files"
    check_status $? "Creating Files directory" "Files Backup"
    if [ "$INCREMENTAL" = true ] && [ -n "$LAST_BACKUP" ]; then
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS --link-dest=\"$LAST_BACKUP/Files\" \"$wpPath/\" \"$DEST/Files\""
    else
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS \"$wpPath/\" \"$DEST/Files\""
    fi
    check_status $? "Files backup with rsync" "Files Backup"

    cd "$DEST"
    compress "Files/" "$FILES_FILENAME"
    check_status $? "Files compression" "Files Backup"
    rm -rf "Files/"
    check_status $? "Cleaning up Files directory" "Files Backup"

    if [ -n "$destinationIP" ]; then
        nice -n "$NICE_LEVEL" rsync -azvrh --progress -e "ssh -p ${destinationPort} -i ${privateKeyPath}" "$FILES_FILENAME" "$destinationUser@$destinationIP:$DESTINATION_PATH/"
        check_status $? "Uploading files backup to remote" "Files Backup"
    else
        mv "$FILES_FILENAME" "$DESTINATION_PATH/"
        check_status $? "Moving files backup to local destination" "Files Backup"
    fi
else
    log "INFO" "Dry run: Skipping files backup"
fi

if [ "$DRY_RUN" = false ]; then
    echo "$DEST" > "$LAST_BACKUP_FILE"
    log "INFO" "Updated last backup reference to $DEST"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
CURRENT_DATE=$(date '+%Y-%m-%d')
log "INFO" "Files backup process for $DIR completed successfully in ${DURATION}s"
update_status "SUCCESS" "Files backup process for $DIR in ${DURATION}s"
notify "SUCCESS" "Files backup process for $DIR completed successfully in ${DURATION}s on $CURRENT_DATE" "Files Backup"