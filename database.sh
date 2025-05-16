#!/bin/bash
# database.sh - WordPress database backup script
# Author: System Administrator
# Last updated: 2025-05-16

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/database.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/database_status.log}"

# Initialize default values
DRY_RUN=false
VERBOSE=false
BACKUP_LOCATION="remote"

# Parse command line options
while getopts "c:f:dlrbv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        l) BACKUP_LOCATION="local";;
        r) BACKUP_LOCATION="remote";;
        b) BACKUP_LOCATION="both";;
        v) VERBOSE=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-v]" >&2
            echo -e "  -c: Configuration file"
            echo -e "  -f: Override compression format (zip, tar.gz, tar)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -l: Store backup locally only"
            echo -e "  -r: Store backup remotely only"
            echo -e "  -b: Store backup both locally and remotely"
            echo -e "  -v: Verbose output"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Database Backup"

# If no config file specified, prompt user to select one
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "database"; then
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

# Validate required configuration variables for WordPress path
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# If backing up remotely or both, validate SSH related configuration variables
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var for remote backup is not set in $CONFIG_FILE!${NC}" >&2
            exit 1
        fi
    done
fi

# Set default directories and options
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
DEST="$BACKUP_DIR/$DIR"
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
DB_FILENAME="${DB_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"

# Function to validate SSH connection
validate_ssh() {
    if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
        check_status $? "SSH connection validation" "Database backup"
    fi
}

# Function for cleanup operations
cleanup_database() {
    cleanup "Database backup process" "Database backup"
    rm -rf "$DEST"
}

trap cleanup_database INT TERM

# Start backup process
log "INFO" "Starting database backup for $DIR to $BACKUP_LOCATION"
update_status "STARTED" "Database backup process for $DIR to $BACKUP_LOCATION"

# Validate SSH connection if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh
    log "INFO" "SSH connection successfully validated"
fi

# Create necessary directories
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR"
    check_status $? "Create backup directory" "Database backup"
    mkdir -pv "$DEST"
    check_status $? "Create destination directory" "Database backup"
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR"
        check_status $? "Create local backups directory" "Database backup"
    fi
else
    log "INFO" "Dry-run mode enabled: skipping directory creation"
fi

# Backup database
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/DB"
    check_status $? "Create DB directory" "Database backup"
    cd "$DEST/DB" || exit 1
    
    echo -e "${CYAN}${BOLD}Exporting database...${NC}"
    nice -n "$NICE_LEVEL" wp db export --add-drop-table --path="$wpPath"
    check_status $? "Export database" "Database backup"
    
    cd "$DEST" || exit 1
    log "DEBUG" "Starting database compression"
    echo -e "${CYAN}${BOLD}Compressing database...${NC}"
    compress "DB/" "$DB_FILENAME"
    check_status $? "Compress database files" "Database backup"
    
    echo -e "${CYAN}${BOLD}Cleaning up temporary files...${NC}"
    nice -n "$NICE_LEVEL" rm -rfv DB/
    check_status $? "Clean up DB directory" "Database backup"

    # Get database backup size
    db_size=$(du -h "$DEST/$DB_FILENAME" | cut -f1)
    log "INFO" "Database backup size: $db_size"

    # Store backup according to specified location
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR"
            echo -e "${CYAN}${BOLD}Moving database backup to local storage...${NC}"
            mv -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Move database backup to local backup directory" "Database backup"
            ;;
        remote)
            log "INFO" "Uploading backup to remote server"
            echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Upload database backup to remote server" "Database backup"
            ;;
        both)
            log "INFO" "Saving backup locally and uploading to remote server"
            echo -e "${CYAN}${BOLD}Copying database backup to local storage...${NC}"
            cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copy database backup to local" "Database backup"
            
            echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Upload database backup to remote server" "Database backup"
            ;;
    esac
else
    log "INFO" "Dry-run mode enabled: skipping database backup execution"
fi

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Database backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Database backup process for $DIR to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}"
notify "SUCCESS" "Database backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Database backup"

echo -e "${GREEN}${BOLD}Database backup completed successfully!${NC}"
echo -e "${GREEN}Backup location: ${NC}${BACKUP_LOCATION}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
echo -e "${GREEN}Database size: ${NC}${db_size:-N/A}"
