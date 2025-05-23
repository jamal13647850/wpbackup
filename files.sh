#!/bin/bash
# File: files.sh

. "$(dirname "$0")/common.sh" # [cite: 180]

LOG_FILE="$SCRIPTPATH/logs/files.log" # [cite: 180]
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/files_status.log}" # [cite: 180]

DRY_RUN=false # [cite: 180]
VERBOSE=false # [cite: 180]
QUIET=false # Added
BACKUP_LOCATION=""  # Will store command-line specified backup location [cite: 180]
INCREMENTAL=false # [cite: 180]
NAME_SUFFIX="" # For custom filename suffix

# Parse command line options
while getopts "c:f:dlrbiqn:v" opt; do # Added 'q' and 'n:'
    case $opt in
        c) CONFIG_FILE="$OPTARG";; # [cite: 181]
        f) OVERRIDE_FORMAT="$OPTARG";; # [cite: 181]
        d) DRY_RUN=true;; # [cite: 181]
        l) BACKUP_LOCATION="local";; # [cite: 182]
        r) BACKUP_LOCATION="remote";; # [cite: 182]
        b) BACKUP_LOCATION="both";; # [cite: 182]
        i) INCREMENTAL=true;; # [cite: 182]
        q) QUIET=true;; # Added
        n) NAME_SUFFIX="$OPTARG";; # Added
        v) VERBOSE=true;; # [cite: 182]
        \?) # [cite: 183]
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-q] [-n <suffix>] [-v]" >&2 # [cite: 183]
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)" # [cite: 183]
            echo -e "  -f: Override compression format (zip, tar.gz, tar)" # [cite: 183]
            echo -e "  -d: Dry run (no actual changes)" # [cite: 183]
            echo -e "  -l: Store backup locally only" # [cite: 184]
            echo -e "  -r: Store backup remotely only" # [cite: 184]
            echo -e "  -b: Store backup both locally and remotely" # [cite: 184]
            echo -e "  -i: Use incremental backup" # [cite: 184]
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" # Added
            echo -e "  -n: Custom suffix for backup filename (e.g., 'files-pre-deploy')" # Added
            echo -e "  -v: Verbose output" # [cite: 184]
            exit 1
            ;;
    esac
done

# --- Interactive prompt for NAME_SUFFIX ---
if [ -z "$NAME_SUFFIX" ] && [ "${QUIET}" = false ]; then
    echo -e "${YELLOW}Do you want to add a custom suffix to the files backup filename? (y/N):${NC}"
    read -r -p "> " confirm_suffix
    if [[ "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Enter custom suffix:${NC}"
        read -r -p "> " interactive_suffix
        if [ -n "$interactive_suffix" ]; then
            NAME_SUFFIX=$(sanitize_filename_suffix "$interactive_suffix")
            if [ -n "$NAME_SUFFIX" ]; then
                 echo -e "${GREEN}Using sanitized suffix: '${NAME_SUFFIX}'${NC}"
            else
                 echo -e "${YELLOW}No valid suffix provided or suffix became empty after sanitization. Proceeding without a custom suffix.${NC}"
            fi
        else
            echo -e "${YELLOW}No suffix entered. Proceeding without a custom suffix.${NC}"
        fi
    else
        echo -e "${INFO}Proceeding without a custom suffix.${NC}"
    fi
elif [ -n "$NAME_SUFFIX" ]; then
    ORIGINAL_CMD_SUFFIX="$NAME_SUFFIX"
    NAME_SUFFIX=$(sanitize_filename_suffix "$NAME_SUFFIX")
    if [ -z "$NAME_SUFFIX" ] && [ -n "$ORIGINAL_CMD_SUFFIX" ]; then
         echo -e "${YELLOW}Warning: Provided suffix '${ORIGINAL_CMD_SUFFIX}' was invalid or became empty. Proceeding without a custom suffix.${NC}"
    elif [ "$NAME_SUFFIX" != "$ORIGINAL_CMD_SUFFIX" ]; then
        echo -e "${YELLOW}Sanitized command-line suffix: '${ORIGINAL_CMD_SUFFIX}' -> '${NAME_SUFFIX}'${NC}"
    fi
fi

init_log "WordPress Files Backup" # [cite: 186]

# Config file processing
if [ -z "$CONFIG_FILE" ]; then # [cite: 186]
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}" # [cite: 186]
    if ! select_config_file "$SCRIPTPATH/configs" "files"; then # [cite: 187]
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2 # [cite: 187]
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then # [cite: 187]
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2 # [cite: 188]
    exit 1
fi # [cite: 188]
process_config_file "$CONFIG_FILE" "Files Backup" # Self-correction: specific process type

# Validate required configuration variables
for var in wpPath; do # [cite: 191]
    if [ -z "${!var}" ]; then # [cite: 192]
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2 # [cite: 192]
        exit 1
    fi
done

# Check SSH settings if remote backup is enabled
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 192]
    for var in destinationPort destinationUser destinationIP destinationFilesBackupPath privateKeyPath; do # [cite: 193]
        if [ -z "${!var}" ]; then # [cite: 194]
            echo -e "${RED}${BOLD}Error: Required SSH variable $var for remote backup is not set in $CONFIG_FILE!${NC}" >&2 # [cite: 195]
            exit 1
        fi
    done
fi

# Define backup directories and names
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}" # [cite: 195]
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}" # [cite: 195]
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}" # [cite: 195]
DEST="$BACKUP_DIR/$DIR" # [cite: 195]
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}" # [cite: 195]
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}" # [cite: 195]
NICE_LEVEL="${NICE_LEVEL:-19}" # [cite: 195]
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}" # [cite: 195]
LOG_LEVEL="${VERBOSE:+verbose}" # [cite: 195]
LOG_LEVEL="${LOG_LEVEL:-normal}" # [cite: 195]
LAST_BACKUP_FILE="$SCRIPTPATH/last_files_backup.txt" # [cite: 195] # Note: this was SCRIPTPATH/last_files_backup.txt in original files.sh

FORMATTED_SUFFIX=""
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}" # [cite: 195]


EXCLUDE_ARGS="" #
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS" # [cite: 195]
for pattern in "${PATTERNS[@]}"; do # [cite: 195]
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'" # [cite: 196]
done

# SSH Validation (uses common.sh function)
# validate_ssh function is in common.sh

cleanup_files() {
    cleanup "Files backup process" "Files backup" #
    rm -rf "$DEST" #
}
trap cleanup_files INT TERM #

# --- Main Backup Logic ---
if ! $QUIET; then
    echo -e "${CYAN}Starting files backup...${NC}"
    echo -e "${INFO}Backup location: ${BOLD}$BACKUP_LOCATION${NC}"
    if [ "$INCREMENTAL" = true ]; then
        echo -e "${INFO}Incremental backup: ${BOLD}Enabled${NC}"
    fi
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${INFO}Filename suffix: ${BOLD}${NAME_SUFFIX}${NC}"
    fi
fi

log "INFO" "Starting files backup for $DIR to $BACKUP_LOCATION (Incremental: $INCREMENTAL, Suffix: $NAME_SUFFIX)" #
update_status "STARTED" "Files backup process for $DIR to $BACKUP_LOCATION" #

if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 198]
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Files backup" # [cite: 197, 198]
    log "INFO" "SSH connection successfully validated" # [cite: 199]
fi

# Create directories
if [ "$DRY_RUN" = false ]; then # [cite: 199]
    mkdir -pv "$BACKUP_DIR" # [cite: 200]
    check_status $? "Create backup directory" "Files backup" # [cite: 200, 201]
    mkdir -pv "$DEST" # [cite: 201]
    check_status $? "Create destination directory" "Files backup" # [cite: 201, 202]
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 202]
        mkdir -pv "$LOCAL_BACKUP_DIR" # [cite: 203]
        check_status $? "Create local backups directory" "Files backup" # [cite: 203, 204]
    fi
else
    log "INFO" "Dry-run mode enabled: skipping directory creation" # [cite: 204]
fi

# Perform backup
FILES_SIZE_VALUE="N/A"
if [ "$DRY_RUN" = false ]; then # [cite: 204]
    mkdir -pv "$DEST/Files" # [cite: 205]
    check_status $? "Create Files directory" "Files backup" # [cite: 205, 206]

    RSYNC_OPTS="-avrh --progress --max-size=\"${maxSize:-50m}\"" # [cite: 206]

    if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ] && [ -d "$(cat "$LAST_BACKUP_FILE" 2>/dev/null)/Files" ]; then # Modified to check $LAST_BACKUP_FILE/Files [cite: 206]
        LAST_BACKUP_BASE_DIR=$(cat "$LAST_BACKUP_FILE") # [cite: 207]
        log "INFO" "Using incremental backup from $LAST_BACKUP_BASE_DIR/Files" # [cite: 207]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Performing incremental files backup...${NC}"; fi # [cite: 207]
        RSYNC_OPTS="$RSYNC_OPTS --link-dest=$LAST_BACKUP_BASE_DIR/Files" # [cite: 207]
    else
        if [ "$INCREMENTAL" = true ]; then # Log if incremental was intended but fallback
            log "WARNING" "Last backup path or its 'Files' subdirectory not found. Performing full files backup instead."
        fi
        log "INFO" "Performing full files backup" # [cite: 207]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Performing full files backup...${NC}"; fi # [cite: 207]
    fi

    eval nice -n "$NICE_LEVEL" rsync $RSYNC_OPTS $EXCLUDE_ARGS "$wpPath/" "$DEST/Files/" # [cite: 207]
    check_status $? "Rsync files" "Files backup" # [cite: 208]

    # Save current backup base path for next incremental
    echo "$DEST" > "$LAST_BACKUP_FILE" # [cite: 208]

    cd "$DEST" || exit 1 # [cite: 208]
    log "DEBUG" "Starting files compression" # [cite: 209]
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing files...${NC}"; fi # [cite: 209]
    compress "Files/" "$FILES_FILENAME" # [cite: 209]
    check_status $? "Compress files" "Files backup" # [cite: 209, 210]

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up temporary Files directory...${NC}"; fi # [cite: 210]
    nice -n "$NICE_LEVEL" rm -rfv Files/ # [cite: 210]
    check_status $? "Clean up Files directory" "Files backup" # [cite: 210, 211]

    FILES_SIZE_VALUE=$(du -h "$DEST/$FILES_FILENAME" | cut -f1) # [cite: 211]
    log "INFO" "Files backup created: $DEST/$FILES_FILENAME (Size: $FILES_SIZE_VALUE)" # [cite: 211]

    case $BACKUP_LOCATION in
        local) #
            log "INFO" "Saving backup locally to $LOCAL_BACKUP_DIR" #
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Moving files backup to local storage...${NC}"; fi #
            mv -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/" #
            check_status $? "Move files backup to local backup directory" "Files backup" # [cite: 212]
            rm -rf "$DEST"
            ;;
        remote) # [cite: 213]
            log "INFO" "Uploading backup to remote server" # [cite: 213]
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"; fi # [cite: 213]
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath" # [cite: 213]
            check_status $? "Upload files backup to remote server" "Files backup" # [cite: 214]
            rm -rf "$DEST"
            ;;
        both) # [cite: 215]
            log "INFO" "Saving backup locally and uploading to remote server" # [cite: 215]
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying files backup to local storage...${NC}"; fi # [cite: 215]
            cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/" # [cite: 215]
            check_status $? "Copy files backup to local" "Files backup" # [cite: 215, 216]

            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"; fi # [cite: 216]
            nice -n "$NICE_LEVEL" rsync -azvrh --progress --compress-level=9 "$DEST/$FILES_FILENAME" \
                -e "ssh -p ${destinationPort:-22} -i ${privateKeyPath}" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath" # [cite: 216]
            check_status $? "Upload files backup to remote server" "Files backup" # [cite: 217]
            rm -rf "$DEST"
            ;;
    esac
else
    log "INFO" "Dry-run mode enabled: skipping files backup execution" # [cite: 218]
fi

# --- Finalization ---
END_TIME=$(date +%s) #
DURATION=$((END_TIME - START_TIME)) #
FORMATTED_DURATION=$(format_duration $DURATION) #
log "INFO" "Files backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" #
update_status "SUCCESS" "Files backup process for $DIR to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}" #
notify "SUCCESS" "Files backup process for $DIR successfully completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Files backup" #

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Files backup completed successfully!${NC}" #
    echo -e "${GREEN}Backup location: ${NC}${BOLD}${BACKUP_LOCATION}${NC}" #
    if [ "$INCREMENTAL" = true ] && [ "$DRY_RUN" = false ]; then
         echo -e "${GREEN}Backup type: ${NC}${BOLD}Incremental${NC}"
    elif [ "$DRY_RUN" = false ]; then
         echo -e "${GREEN}Backup type: ${NC}${BOLD}Full${NC}"
    fi
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom suffix: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}" #
    FINAL_FILES_PATH_INFO=""
    if [ "$DRY_RUN" = false ]; then
        case "$BACKUP_LOCATION" in
            "local") FINAL_FILES_PATH_INFO="$LOCAL_BACKUP_DIR/$FILES_FILENAME";;
            "remote") FINAL_FILES_PATH_INFO="$destinationUser@$destinationIP:$destinationFilesBackupPath/$FILES_FILENAME";;
            "both") FINAL_FILES_PATH_INFO="$LOCAL_BACKUP_DIR/$FILES_FILENAME and remote";;
        esac
        echo -e "${GREEN}Files backup: ${NC}$FINAL_FILES_PATH_INFO (${FILES_SIZE_VALUE})"
    else
        echo -e "${GREEN}Filename (dry run): ${NC}${FILES_FILENAME}"
    fi
fi