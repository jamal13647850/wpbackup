#!/bin/bash
# backup.sh - Complete WordPress backup script (database + files)
# Author: System Administrator
# Last updated: 2025-05-16

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/backup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/backup_status.log}"
LAST_BACKUP_FILE="$SCRIPTPATH/last_backup.txt"

# Initialize default values
DRY_RUN=false
CLI_BACKUP_LOCATION=""  # This will store the command-line specified backup location
VERBOSE=false
INCREMENTAL=false

# Parse command line options
while getopts "c:f:dlrbiv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        l) CLI_BACKUP_LOCATION="local";;
        r) CLI_BACKUP_LOCATION="remote";;
        b) CLI_BACKUP_LOCATION="both";;
        i) INCREMENTAL=true;;
        v) VERBOSE=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-v]" >&2
            echo -e "  -c: Configuration file"
            echo -e "  -f: Override compression format (zip, tar.gz, tar)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -l: Store backup locally only"
            echo -e "  -r: Store backup remotely only"
            echo -e "  -b: Store backup both locally and remotely"
            echo -e "  -i: Use incremental backup for files"
            echo -e "  -v: Verbose output"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Backup"

# If no config file specified, prompt user to select one
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "backup"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$CONFIG_FILE")${NC}"
fi

# Source the config file
. "$CONFIG_FILE"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Set default directories
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"

# Command line options take precedence over config file
BACKUP_LOCATION="${CLI_BACKUP_LOCATION:-${BACKUP_LOCATION:-remote}}"

# Set up file paths and options
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

# Validate SSH settings if remote backup is selected
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in $CONFIG_FILE for remote backup!${NC}" >&2
            exit 1
        fi
    done
fi

# Process exclude patterns for rsync
EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude '$pattern'"
done

# Function to validate SSH connection
validate_ssh() {
    ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
    check_status $? "SSH connection validation" "Backup"
}

# Function for cleanup operations
cleanup_backup() {
    cleanup "Backup process" "Backup"
    rm -rf "$DEST"
}
trap cleanup_backup INT TERM

# Start backup process
log "INFO" "Starting backup process for $DIR to $BACKUP_LOCATION (Incremental Files: $INCREMENTAL)"
update_status "STARTED" "Backup process for $DIR to $BACKUP_LOCATION"

# Validate SSH connection if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh
    log "INFO" "SSH connection validated successfully"
fi

# Create necessary directories
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

# Check for last backup for incremental backup
LAST_BACKUP=""
if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ]; then
    LAST_BACKUP=$(cat "$LAST_BACKUP_FILE")
    log "INFO" "Using last backup as reference for incremental files: $LAST_BACKUP"
elif [ "$INCREMENTAL" = true ]; then
    log "WARNING" "No previous backup found, falling back to full files backup"
    INCREMENTAL=false
fi

# Backup database
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/DB"
    check_status $? "Creating DB directory" "Backup"
    cd "$DEST/DB" || exit 1
    echo -e "${CYAN}${BOLD}Exporting database...${NC}"
    nice -n "$NICE_LEVEL" wp db export --add-drop-table --path="$wpPath"
    check_status $? "Full database export" "Backup"
    cd "$DEST" || exit 1
    log "DEBUG" "Starting database compression"
    echo -e "${CYAN}${BOLD}Compressing database...${NC}"
    (compress "DB/" "$DB_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv DB/) &
    DB_PID=$!
else
    log "INFO" "Dry run: Skipping database backup"
fi

# Backup files
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/Files"
    check_status $? "Creating Files directory" "Backup"
    echo -e "${CYAN}${BOLD}Backing up files...${NC}"
    if [ "$INCREMENTAL" = true ] && [ -n "$LAST_BACKUP" ]; then
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS --link-dest=\"$LAST_BACKUP/Files\" \"$wpPath/\" \"$DEST/Files\""
        check_status $? "Incremental files backup with rsync" "Backup"
    else
        eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS \"$wpPath/\" \"$DEST/Files\""
        check_status $? "Full files backup with rsync" "Backup"
    fi
    cd "$DEST" || exit 1
    log "DEBUG" "Starting files compression"
    echo -e "${CYAN}${BOLD}Compressing files...${NC}"
    (compress "Files/" "$FILES_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv Files/) &
    FILES_PID=$!
else
    log "INFO" "Dry run: Skipping files backup"
fi

# Wait for compression to complete and get sizes
if [ "$DRY_RUN" = false ]; then
    wait $DB_PID
    check_status $? "Database compression and cleanup" "Backup"
    db_size=$(du -h "$DEST/$DB_FILENAME" | cut -f1)
    log "INFO" "Database backup size: $db_size"

    wait $FILES_PID
    check_status $? "Files compression and cleanup" "Backup"
    files_size=$(du -h "$DEST/$FILES_FILENAME" | cut -f1)
    log "INFO" "Files backup size: $files_size"
fi

# Update last backup reference for future incremental backups
if [ "$DRY_RUN" = false ]; then
    echo "$DEST" > "$LAST_BACKUP_FILE"
    log "INFO" "Updated last backup reference to $DEST"
fi

# Store backup according to specified location
if [ "$DRY_RUN" = false ]; then
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR"
            echo -e "${CYAN}${BOLD}Moving backups to local storage...${NC}"
            mv -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Moving database backup to local" "Backup"
            mv -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Moving files backup to local" "Backup"
            ;;
        remote)
            log "INFO" "Uploading backup to remote server"
            echo -e "${CYAN}${BOLD}Uploading backups to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Uploading database backup" "Backup"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Uploading files backup" "Backup"
            ;;
        both)
            log "INFO" "Saving backup locally and uploading to remote server"
            echo -e "${CYAN}${BOLD}Copying backups to local storage...${NC}"
            cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying database backup to local" "Backup"
            cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying files backup to local" "Backup"

            echo -e "${CYAN}${BOLD}Uploading backups to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Uploading database backup" "Backup"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Uploading files backup" "Backup"
            ;;
    esac
else
    log "INFO" "Dry run: Skipping backup storage to $BACKUP_LOCATION"
fi

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Backup process for $DIR to $BACKUP_LOCATION in ${FORMATTED_DURATION}"
notify "SUCCESS" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Backup"

echo -e "${GREEN}${BOLD}Backup completed successfully!${NC}"
echo -e "${GREEN}Backup location: ${NC}${BACKUP_LOCATION}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
echo -e "${GREEN}Database size: ${NC}${db_size:-N/A}"
echo -e "${GREEN}Files size: ${NC}${files_size:-N/A}"
