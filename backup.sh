#!/bin/bash
# backup.sh - WordPress backup script
# Author: System Administrator
# Last updated: 2025-05-17

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/logs/backup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/backup_status.log}"
LAST_BACKUP_FILE="$SCRIPTPATH/logs/last_backup.txt"

# Initialize default values
DRY_RUN=false
CLI_BACKUP_LOCATION=""  # This will store the command-line specified backup location
VERBOSE=false
INCREMENTAL=false
BACKUP_TYPE="full"  # Default to full backup (both DB and files)

# Parse command line options
while getopts "c:f:dlrbit:qv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        l) CLI_BACKUP_LOCATION="local";;
        r) CLI_BACKUP_LOCATION="remote";;
        b) CLI_BACKUP_LOCATION="both";;
        i) INCREMENTAL=true;;
        t) BACKUP_TYPE="$OPTARG";;
        q) QUIET=true;;
        v) VERBOSE=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-t <type>] [-q] [-v]" >&2
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  -f: Override compression format (zip, tar.gz, tar)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -l: Store backup locally only"
            echo -e "  -r: Store backup remotely only"
            echo -e "  -b: Store backup both locally and remotely"
            echo -e "  -i: Use incremental backup for files"
            echo -e "  -t: Backup type (full, db, files)"
            echo -e "  -q: Quiet mode (minimal output)"
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
fi

# Process the configuration file (handles both encrypted and regular files)
process_config_file "$CONFIG_FILE" "Backup"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Set default values
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"

# Set backup location from command line or config file
BACKUP_LOCATION="${CLI_BACKUP_LOCATION:-${BACKUP_LOCATION:-remote}}"

# Set other variables
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

# Validate remote backup settings if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in $CONFIG_FILE for remote backup!${NC}" >&2
            exit 1
        fi
    done
fi

# Prepare exclude arguments for rsync
EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude '$pattern'"
done

# Function for cleanup operations specific to backup
cleanup_backup() {
    cleanup "Backup process" "Backup"
    rm -rf "$DEST"
}
trap cleanup_backup INT TERM

# Log start of backup process
log "INFO" "Starting backup process for $DIR to $BACKUP_LOCATION (Incremental Files: $INCREMENTAL, Type: $BACKUP_TYPE)"
update_status "STARTED" "Backup process for $DIR to $BACKUP_LOCATION"

# Validate SSH connection if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Backup"
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

# Check for last backup for incremental mode
LAST_BACKUP=""
if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ]; then
    LAST_BACKUP=$(cat "$LAST_BACKUP_FILE")
    log "INFO" "Using last backup as reference for incremental files: $LAST_BACKUP"
elif [ "$INCREMENTAL" = true ]; then
    log "WARNING" "No previous backup found, falling back to full files backup"
    INCREMENTAL=false
fi

# Backup database if needed
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
    if [ "$DRY_RUN" = false ]; then
        mkdir -pv "$DEST/DB"
        check_status $? "Creating DB directory" "Backup"
        cd "$DEST/DB" || exit 1
        echo -e "${CYAN}${BOLD}Exporting database...${NC}"
        wp_cli db export --add-drop-table --path="$wpPath"
        check_status $? "Full database export" "Backup"
        cd "$DEST" || exit 1
        log "DEBUG" "Starting database compression"
        echo -e "${CYAN}${BOLD}Compressing database...${NC}"
        (compress "DB/" "$DB_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv DB/) &
        DB_PID=$!
    else
        log "INFO" "Dry run: Skipping database backup"
    fi
fi

# Backup files if needed
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
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
fi

# Wait for compression processes to finish
if [ "$DRY_RUN" = false ]; then
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
        wait $DB_PID
        check_status $? "Database compression and cleanup" "Backup"
        log "INFO" "Database backup completed"
    fi
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
        wait $FILES_PID
        check_status $? "Files compression and cleanup" "Backup"
        log "INFO" "Files backup completed"
    fi
fi

# Transfer backups to local storage if needed
if [ "$DRY_RUN" = false ] && [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    echo -e "${CYAN}${BOLD}Copying backups to local storage...${NC}"
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
        cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
        check_status $? "Copying database backup to local storage" "Backup"
    fi
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
        cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
        check_status $? "Copying files backup to local storage" "Backup"
    fi
    
    log "INFO" "Backups copied to local storage"
fi

# Transfer backups to remote storage if needed
if [ "$DRY_RUN" = false ] && [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    echo -e "${CYAN}${BOLD}Transferring backups to remote storage...${NC}"
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
        nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$DB_FILENAME" "$destinationUser@$destinationIP:$destinationDbBackupPath"
        check_status $? "Transferring database backup to remote storage" "Backup"
    fi
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
        nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$FILES_FILENAME" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
        check_status $? "Transferring files backup to remote storage" "Backup"
    fi
    
    log "INFO" "Backups transferred to remote storage"
fi

# Save current backup path for future incremental backups
if [ "$DRY_RUN" = false ] && [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
    echo "$DEST" > "$LAST_BACKUP_FILE"
    log "INFO" "Saved current backup path for future incremental backups"
fi

# Clean up temporary files
if [ "$DRY_RUN" = false ]; then
    if [ "$BACKUP_LOCATION" = "remote" ]; then
        echo -e "${CYAN}${BOLD}Cleaning up local temporary files...${NC}"
        rm -rf "$DEST"
        check_status $? "Cleaning up local temporary files" "Backup"
    fi
fi

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Backup process completed successfully in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Backup process for $DIR completed in ${FORMATTED_DURATION}"

notify "SUCCESS" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Backup"

echo -e "${GREEN}${BOLD}Backup process completed successfully!${NC}"
echo -e "${GREEN}Backup location: ${NC}${BACKUP_LOCATION}"
echo -e "${GREEN}Backup type: ${NC}${BACKUP_TYPE}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"

if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
    if [ -f "$DEST/$DB_FILENAME" ]; then
        DB_SIZE=$(du -h "$DEST/$DB_FILENAME" | cut -f1)
        echo -e "${GREEN}Database backup size: ${NC}${DB_SIZE}"
    fi
fi

if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
    if [ -f "$DEST/$FILES_FILENAME" ]; then
        FILES_SIZE=$(du -h "$DEST/$FILES_FILENAME" | cut -f1)
        echo -e "${GREEN}Files backup size: ${NC}${FILES_SIZE}"
    fi
fi
