#!/bin/bash
# files.sh - WordPress files backup script
# Author: System Administrator
# Last updated: 2025-05-17

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/files.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/files_status.log}"

# Initialize default values
DRY_RUN=false
VERBOSE=false
CLI_BACKUP_LOCATION=""  # Will store command-line specified backup location
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
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  -f: Override compression format (zip, tar.gz, tar)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -l: Store backup locally only"
            echo -e "  -r: Store backup remotely only"
            echo -e "  -b: Store backup both locally and remotely"
            echo -e "  -i: Use incremental backup"
            echo -e "  -v: Verbose output"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Files Backup"

# If no config file specified, prompt user to select one
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "files"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$CONFIG_FILE")${NC}"
fi

# Source the config file - handle both encrypted and regular files
if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
    if ! command_exists gpg; then
        echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
        exit 1
    fi
    echo -e "${CYAN}Loading encrypted configuration file...${NC}"
    eval "$(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)"
    if [ $? -ne 0 ]; then
        echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2
        exit 1
    fi
    log "INFO" "Successfully loaded encrypted configuration file: $(basename "$CONFIG_FILE")"
else
    . "$CONFIG_FILE"
    log "INFO" "Successfully loaded configuration file: $(basename "$CONFIG_FILE")"
fi

# Set backup location from command line or config file
BACKUP_LOCATION="${CLI_BACKUP_LOCATION:-both}"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Check SSH settings if remote backup is enabled
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var for remote backup is not set in $CONFIG_FILE!${NC}" >&2
            exit 1
        fi
    done
fi

# Set default values
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
DEST="$BACKUP_DIR/$DIR"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}"
LAST_BACKUP_FILE="$SCRIPTPATH/last_files_backup.txt"

# Process exclude patterns
EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'"
done

# Function to validate SSH connection
validate_ssh() {
    if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        echo -e "${CYAN}Validating SSH connection...${NC}"
        ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
        check_status $? "SSH connection validation" "Files backup"
    fi
}

# Function for cleanup operations
cleanup_files() {
    cleanup "Files backup process" "Files backup"
    rm -rf "$DEST"
}
trap cleanup_files INT TERM

# Start backup process
log "INFO" "Starting files backup for $DIR to $BACKUP_LOCATION (Incremental: $INCREMENTAL)"
update_status "STARTED" "Files backup process for $DIR to $BACKUP_LOCATION"

# Validate SSH connection if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh
    log "INFO" "SSH connection successfully validated"
fi

# Create necessary directories
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR"
    check_status $? "Create backup directory" "Files backup"
    mkdir -pv "$DEST"
    check_status $? "Create destination directory" "Files backup"
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR"
        check_status $? "Create local backups directory" "Files backup"
    fi
else
    log "INFO" "Dry-run mode enabled: skipping directory creation"
fi

# Perform files backup
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$DEST/Files"
    check_status $? "Create Files directory" "Files backup"
    
    # Determine rsync options based on incremental flag
    RSYNC_OPTS="-avrh --progress --max-size=\"${maxSize:-50m}\""
    
    if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ] && [ -d "$(cat "$LAST_BACKUP_FILE" 2>/dev/null)" ]; then
        LAST_BACKUP=$(cat "$LAST_BACKUP_FILE")
        log "INFO" "Using incremental backup from $LAST_BACKUP"
        echo -e "${CYAN}${BOLD}Performing incremental files backup...${NC}"
        RSYNC_OPTS="$RSYNC_OPTS --link-dest=$LAST_BACKUP/Files"
    else
        log "INFO" "Performing full files backup"
        echo -e "${CYAN}${BOLD}Performing full files backup...${NC}"
    fi
    
    # Execute rsync with all options
    eval nice -n "$NICE_LEVEL" rsync $RSYNC_OPTS $EXCLUDE_ARGS "$wpPath/" "$DEST/Files/"
    check_status $? "Rsync files" "Files backup"
    
    # Save current backup path for future incremental backups
    echo "$DEST" > "$LAST_BACKUP_FILE"
    
    cd "$DEST" || exit 1
    log "DEBUG" "Starting files compression"
    echo -e "${CYAN}${BOLD}Compressing files...${NC}"
    compress "Files/" "$FILES_FILENAME"
    check_status $? "Compress files" "Files backup"
    
    echo -e "${CYAN}${BOLD}Cleaning up temporary files...${NC}"
    nice -n "$NICE_LEVEL" rm -rfv Files/
    check_status $? "Clean up Files directory" "Files backup"
    
    # Get files backup size
    files_size=$(du -h "$DEST/$FILES_FILENAME" | cut -f1)
    log "INFO" "Files backup size: $files_size"
    
    # Store backup according to selected location
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR"
            echo -e "${CYAN}${BOLD}Moving files backup to local storage...${NC}"
            mv -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Move files backup to local backup directory" "Files backup"
            ;;
        remote)
            log "INFO" "Uploading backup to remote server"
            echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Upload files backup to remote server" "Files backup"
            ;;
        both)
            log "INFO" "Saving backup locally and uploading to remote server"
            echo -e "${CYAN}${BOLD}Copying files backup to local storage...${NC}"
            cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copy files backup to local" "Files backup"
            
            echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Upload files backup to remote server" "Files backup"
            ;;
    esac
else
    log "INFO" "Dry-run mode enabled: skipping files backup execution"
fi

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Files backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Files backup process for $DIR to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}"
notify "SUCCESS" "Files backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Files backup"

echo -e "${GREEN}${BOLD}Files backup completed successfully!${NC}"
echo -e "${GREEN}Backup location: ${NC}${BACKUP_LOCATION}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
echo -e "${GREEN}Files size: ${NC}${files_size:-N/A}"
