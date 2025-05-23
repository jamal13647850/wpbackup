#!/bin/bash
# File: database.sh

# Source common functions and variables
. "$(dirname "$0")/common.sh" # [cite: 144]

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/database.log" # [cite: 144]
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/database_status.log}" # [cite: 144]

# --- Default values for options ---
DRY_RUN=false # [cite: 144]
VERBOSE=false # [cite: 144]
QUIET=false # Added QUIET mode
BACKUP_LOCATION="remote" # [cite: 144] Initial default, can be changed by config or CLI
NAME_SUFFIX="" # For custom filename suffix

# Parse command line options
while getopts "c:f:dlrbqn:v" opt; do # Added 'q' for quiet and 'n:' for name_suffix
    case $opt in
        c) CONFIG_FILE="$OPTARG";; # [cite: 145]
        f) OVERRIDE_FORMAT="$OPTARG";; # [cite: 145]
        d) DRY_RUN=true;; # [cite: 145]
        l) BACKUP_LOCATION="local";; # [cite: 145]
        r) BACKUP_LOCATION="remote";; # [cite: 145]
        b) BACKUP_LOCATION="both";; # [cite: 145]
        q) QUIET=true;; # Added
        n) NAME_SUFFIX="$OPTARG";; # Added
        v) VERBOSE=true;; # [cite: 145]
        \?) # [cite: 146]
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-q] [-n <suffix>] [-v]" >&2 #
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)" >&2 #
            echo -e "  -f: Override compression format (zip, tar.gz, tar)" >&2 #
            echo -e "  -d: Dry run (no actual changes)" >&2 #
            echo -e "  -l: Store backup locally only" >&2 # [cite: 147]
            echo -e "  -r: Store backup remotely only" >&2 # [cite: 147]
            echo -e "  -b: Store backup both locally and remotely" >&2 # [cite: 147]
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" >&2
            echo -e "  -n: Custom suffix for backup filename (e.g., 'db-schema-change')" >&2
            echo -e "  -v: Verbose output" >&2 # [cite: 147]
            exit 1
            ;;
    esac # [cite: 148]
done

# --- Interactive prompt for NAME_SUFFIX if not provided via -n and not in QUIET mode ---
if [ -z "$NAME_SUFFIX" ] && [ "${QUIET}" = false ]; then
    echo -e "${YELLOW}Do you want to add a custom suffix to the database backup filename? (y/N):${NC}"
    read -r -p "> " confirm_suffix
    if [[ "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Enter custom suffix:${NC}"
        read -r -p "> " interactive_suffix
        if [ -n "$interactive_suffix" ]; then
            NAME_SUFFIX=$(sanitize_filename_suffix "$interactive_suffix") # Uses function from common.sh
            if [ -n "$NAME_SUFFIX" ]; then
                 echo -e "${GREEN}Using sanitized suffix: '${NAME_SUFFIX}'${NC}"
            else
                 echo -e "${YELLOW}No valid suffix provided or suffix became empty after sanitization. Proceeding without a custom suffix.${NC}"
            fi
        else
            echo -e "${YELLOW}No suffix entered. Proceeding without a custom suffix.${NC}"
        fi
    else
        # User chose not to add a suffix interactively
        if ! $QUIET; then # Only print if not in quiet mode
             echo -e "${INFO}Proceeding without a custom suffix.${NC}" # Using INFO color from common.sh potentially
        fi
    fi
elif [ -n "$NAME_SUFFIX" ]; then
    # Sanitize suffix if provided via -n
    ORIGINAL_CMD_SUFFIX="$NAME_SUFFIX"
    NAME_SUFFIX=$(sanitize_filename_suffix "$NAME_SUFFIX") # Uses function from common.sh
    if [ -z "$NAME_SUFFIX" ] && [ -n "$ORIGINAL_CMD_SUFFIX" ]; then # If suffix became empty
         echo -e "${YELLOW}Warning: Provided suffix '${ORIGINAL_CMD_SUFFIX}' was invalid or became empty after sanitization. Proceeding without a custom suffix.${NC}"
    elif [ "$NAME_SUFFIX" != "$ORIGINAL_CMD_SUFFIX" ] && [ -n "$NAME_SUFFIX" ]; then # If suffix changed and is not empty
        echo -e "${YELLOW}Sanitized command-line suffix: '${ORIGINAL_CMD_SUFFIX}' -> '${NAME_SUFFIX}'${NC}"
    fi
fi

# Initialize log (after QUIET is potentially set and suffix handled)
init_log "WordPress Database Backup" # [cite: 148]

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then # [cite: 148]
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}" # [cite: 148]
    if ! select_config_file "$SCRIPTPATH/configs" "database"; then # [cite: 149]
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2 # [cite: 149]
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then # [cite: 150]
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2 # [cite: 150]
    exit 1
fi # [cite: 150]
# process_config_file function will be called from common.sh and handles its own messages
process_config_file "$CONFIG_FILE" "Database Backup" # (Similar logic)

# Validate required configuration variables
for var in wpPath; do # [cite: 154]
    if [ -z "${!var}" ]; then # [cite: 154]
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2 # [cite: 154]
        exit 1
    fi
done

# Check SSH settings if remote backup is enabled
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 155]
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath privateKeyPath; do # [cite: 155]
        if [ -z "${!var}" ]; then # [cite: 156]
            echo -e "${RED}${BOLD}Error: Required SSH variable $var for remote backup is not set in $CONFIG_FILE!${NC}" >&2 # [cite: 157]
            exit 1
        fi
    done
fi

# --- Define backup directories and final filenames ---
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}" # [cite: 157] (DIR from common.sh, or overridden by config)
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}" # [cite: 157]
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}" # [cite: 157]
DEST="$BACKUP_DIR/$DIR" # [cite: 157]
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}" # [cite: 157]
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}" # [cite: 157]
NICE_LEVEL="${NICE_LEVEL:-19}" # [cite: 157]
LOG_LEVEL="${VERBOSE:+verbose}" # [cite: 157]
LOG_LEVEL="${LOG_LEVEL:-normal}" # [cite: 157]

FORMATTED_SUFFIX=""
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi
DB_FILENAME="${DB_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}" # [cite: 157] (Modified)

# Cleanup function trap
cleanup_database() {
    cleanup "Database backup process" "Database backup" #
    rm -rf "$DEST" #
}
trap cleanup_database INT TERM #

# --- Main Backup Logic ---
if ! $QUIET; then
    echo -e "${CYAN}Starting database backup...${NC}"
    echo -e "${INFO}Backup location: ${BOLD}$BACKUP_LOCATION${NC}"
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${INFO}Filename suffix: ${BOLD}${NAME_SUFFIX}${NC}"
    fi
fi

log "INFO" "Starting database backup for $DIR to $BACKUP_LOCATION (Suffix: $NAME_SUFFIX)" # [cite: 159]
update_status "STARTED" "Database backup process for $DIR to $BACKUP_LOCATION" # [cite: 159]

# Validate SSH if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 160]
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Database backup" # Similar to [cite: 158, 159] but using common.sh
    log "INFO" "SSH connection successfully validated" # [cite: 160]
fi

# Create directories
if [ "$DRY_RUN" = false ]; then # [cite: 161]
    mkdir -pv "$BACKUP_DIR" # [cite: 161]
    check_status $? "Create backup directory" "Database backup" # [cite: 162]
    mkdir -pv "$DEST" # [cite: 162]
    check_status $? "Create destination directory" "Database backup" # [cite: 163]
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 163]
        mkdir -pv "$LOCAL_BACKUP_DIR" # [cite: 164]
        check_status $? "Create local backups directory" "Database backup" # [cite: 165]
    fi
else
    log "INFO" "Dry-run mode enabled: skipping directory creation" # [cite: 165]
fi

# Perform backup
DB_SIZE_VALUE="N/A"
if [ "$DRY_RUN" = false ]; then # [cite: 166]
    mkdir -pv "$DEST/DB" # [cite: 166]
    check_status $? "Create DB directory" "Database backup" # [cite: 167]
    cd "$DEST/DB" || exit 1 # [cite: 167]

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Exporting database...${NC}"; fi # [cite: 168]
    wp_cli db export --add-drop-table --path="$wpPath" # [cite: 168]
    check_status $? "Export database" "Database backup" # [cite: 169]

    cd "$DEST" || exit 1 # [cite: 169]
    log "DEBUG" "Starting database compression" # [cite: 170]
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing database...${NC}"; fi # [cite: 170]
    compress "DB/" "$DB_FILENAME" # [cite: 170]
    check_status $? "Compress database files" "Database backup" # [cite: 171]

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up temporary DB directory...${NC}"; fi # [cite: 171]
    nice -n "$NICE_LEVEL" rm -rfv DB/ # [cite: 171]
    check_status $? "Clean up DB directory" "Database backup" # [cite: 172]

    if [ -f "$DEST/$DB_FILENAME" ]; then # Check if file exists before getting size
        DB_SIZE_VALUE=$(du -h "$DEST/$DB_FILENAME" | cut -f1) # [cite: 172]
    fi
    log "INFO" "Database backup created: $DEST/$DB_FILENAME (Size: $DB_SIZE_VALUE)" # [cite: 172]

    case $BACKUP_LOCATION in
        local) # [cite: 172]
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR" # [cite: 172]
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Moving database backup to local storage...${NC}"; fi # [cite: 172]
            mv -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/" # [cite: 172]
            check_status $? "Move database backup to local backup directory" "Database backup" # [cite: 173]
            rm -rf "$DEST" # Clean up the timestamped backup dir
            ;;
        remote) # [cite: 174]
            log "INFO" "Uploading backup to remote server" # [cite: 174]
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"; fi # [cite: 174]
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath" # [cite: 174]
            check_status $? "Upload database backup to remote server" "Database backup" # [cite: 175]
            rm -rf "$DEST" # Clean up after remote transfer
            ;;
        both) # [cite: 176]
            log "INFO" "Saving backup locally and uploading to remote server" # [cite: 176]
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying database backup to local storage...${NC}"; fi # [cite: 176]
            cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/" # [cite: 176]
            check_status $? "Copy database backup to local" "Database backup" # [cite: 177]

            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"; fi # [cite: 177]
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$DB_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath" # [cite: 177]
            check_status $? "Upload database backup to remote server" "Database backup" # [cite: 178]
            rm -rf "$DEST" # Clean up DEST as its now in local_backups and remote
            ;;
    esac # [cite: 179]
else
    log "INFO" "Dry-run mode enabled: skipping database backup execution" # [cite: 179]
fi

# --- Finalization ---
END_TIME=$(date +%s) #
DURATION=$((END_TIME - START_TIME)) #
FORMATTED_DURATION=$(format_duration $DURATION) #
log "INFO" "Database backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" #
update_status "SUCCESS" "Database backup process for $DIR to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}" #
notify "SUCCESS" "Database backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Database backup" #

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Database backup completed successfully!${NC}" #
    echo -e "${GREEN}Backup location: ${NC}${BOLD}${BACKUP_LOCATION}${NC}" #
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom suffix: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}" #
    FINAL_DB_PATH_INFO=""
    if [ "$DRY_RUN" = false ]; then
        case "$BACKUP_LOCATION" in
            "local") FINAL_DB_PATH_INFO="$LOCAL_BACKUP_DIR/$DB_FILENAME";;
            "remote") FINAL_DB_PATH_INFO="$destinationUser@$destinationIP:$destinationDbBackupPath/$DB_FILENAME";;
            "both") FINAL_DB_PATH_INFO="$LOCAL_BACKUP_DIR/$DB_FILENAME and remote";;
        esac
        echo -e "${GREEN}Database backup: ${NC}$FINAL_DB_PATH_INFO (${DB_SIZE_VALUE:-N/A})" # Use DB_SIZE_VALUE
    else
        echo -e "${GREEN}Filename (dry run): ${NC}${DB_FILENAME}"
    fi
fi