#!/usr/bin/env bash

. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/backup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/backup_status.log}"
LAST_BACKUP_FILE="$SCRIPTPATH/last_backup.txt"

DRY_RUN=false
BACKUP_LOCATION=""
VERBOSE=false
INCREMENTAL=false
while getopts "c:f:dlrbiv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        l) BACKUP_LOCATION="local";;
        r) BACKUP_LOCATION="remote";;
        b) BACKUP_LOCATION="both";;
        i) INCREMENTAL=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-v]" >&2; exit 1;;
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
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
BACKUP_LOCATION="${BACKUP_LOCATION:-${BACKUP_LOCATION:-remote}}"
DEST="$BACKUP_DIR/$DIR"
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
DB_FILENAME="${DB_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"

if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo "Error: Required SSH variable $var is not set in $CONFIG_FILE for remote backup!" >&2
            exit 1
        fi
    done
fi

EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude '$pattern'"
done

validate_ssh() {
    ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
    check_status $? "SSH connection validation" "Backup"
}

cleanup_backup() {
    cleanup "Backup process" "Backup"
    rm -rf "$DEST"
}
trap cleanup_backup INT TERM

log "INFO" "Starting backup process for $DIR to $BACKUP_LOCATION (Incremental Files: $INCREMENTAL)"
update_status "STARTED" "Backup process for $DIR to $BACKUP_LOCATION"

if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh
    log "INFO" "SSH connection validated successfully"
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR"
    check_status $? "Creating backups directory" "Backup"
    mkdir -pv "$DEST"
    check_status $? "Creating destination directory" "Backup"
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR"
        check_status $? "Creating local backups directory" "Backup"
    fi
else
    log "INFO" "Dry run: Skipping directory creation"
fi

LAST_BACKUP=""
if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ]; then
    LAST_BACKUP=$(cat "$LAST_BACKUP_FILE")
    log "INFO" "Using last backup as reference for incremental files: $LAST_BACKUP"
elif [ "$INCREMENTAL" = true ]; then
    log "WARNING" "No previous backup found, falling back to full files backup"
    INCREMENTAL=false
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/DB"
    check_status $? "Creating DB directory" "Backup"
    cd "$DEST/DB"
    nice -n "$NICE_LEVEL" wp db export --add-drop-table --path="$wpPath"
    check_status $? "Full database export" "Backup"
    cd "$DEST"
    log "DEBUG" "Starting database compression"
    (compress "DB/" "$DB_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv DB/) &
    DB_PID=$!
else
    log "INFO" "Dry run: Skipping database backup"
fi

if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/Files"
    check_status $? "Creating Files directory" "Backup"
    if [ "$INCREMENTAL" = true ] && [ -n "$LAST_BACKUP" ]; then
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS --link-dest=\"$LAST_BACKUP/Files\" \"$wpPath/\" \"$DEST/Files\""
        check_status $? "Incremental files backup with rsync" "Backup"
    else
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS \"$wpPath/\" \"$DEST/Files\""
        check_status $? "Full files backup with rsync" "Backup"
    fi
    cd "$DEST"
    log "DEBUG" "Starting files compression"
    (compress "Files/" "$FILES_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv Files/) &
    FILES_PID=$!
else
    log "INFO" "Dry run: Skipping files backup"
fi

if [ "$DRY_RUN" = false ]; then
    wait $DB_PID
    check_status $? "Database compression and cleanup" "Backup"
    local db_size=$(du -h "$DEST/$DB_FILENAMEa "$DEST/$DB_FILENAME" | cut -f1)
    log "INFO" "Database backup size: $db_size"
    wait $FILES_PID
    check_status $? "Files compression and cleanup" "Backup"
    local files_size=$(du -h "$DEST/$FILES_FILENAME" | cut -f1)
    log "INFO" "Files backup size: $files_size"
fi

if [ "$DRY_RUN" = false ]; then
    echo "$DEST" > "$LAST_BACKUP_FILE"
    log "INFO" "Updated last backup reference to $DEST"
fi

if [ "$DRY_RUN" = false ]; then
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR"
            mv -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Moving database backup to local" "Backup"
            mv -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Moving files backup to local" "Backup"
            ;;
        remote)
            log "INFO" "Uploading backup to remote server"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Uploading database backup" "Backup"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Uploading files backup" "Backup"
            ;;
        both)
            log "INFO" "Saving backup locally and uploading to remote server"
            cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying database backup to local" "Backup"
            cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying files backup to local" "Backup"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Uploading database backup" "Backup"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Uploading files backup" "Backup"
            ;;
    esac
else
    log "INFO" "Dry run: Skipping backup storage to $BACKUP_LOCATION"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${DURATION}s"
update_status "SUCCESS" "Backup process for $DIR to $BACKUP_LOCATION in ${DURATION}s"
notify "SUCCESS" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${DURATION}s" "Backup"