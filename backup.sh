#!/bin/bash
# File: backup.sh

# Source common functions and variables
. "$(dirname "$0")/common.sh" # [cite: 14]

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/backup.log" # [cite: 14]
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/backup_status.log}" # [cite: 14]
LAST_BACKUP_FILE="$SCRIPTPATH/logs/last_backup.txt" # [cite: 14]

# --- Default values for options ---
DRY_RUN=false # [cite: 14]
CLI_BACKUP_LOCATION=""  # This will store the command-line specified backup location [cite: 14]
VERBOSE=false # [cite: 14]
QUIET=false # Initialize QUIET, will be set by -q
INCREMENTAL=false # [cite: 14]
BACKUP_TYPE="full" # [cite: 14]
NAME_SUFFIX="" # For custom filename suffix

# Parse command line options
while getopts "c:f:dlrbit:qn:v" opt; do # Added 'n:' for name_suffix and 'q' for quiet
    case $opt in
        c) CONFIG_FILE="$OPTARG";; # [cite: 15]
        f) OVERRIDE_FORMAT="$OPTARG";; # [cite: 15]
        d) DRY_RUN=true;; # [cite: 15]
        l) CLI_BACKUP_LOCATION="local";; # [cite: 16]
        r) CLI_BACKUP_LOCATION="remote";; # [cite: 16]
        b) CLI_BACKUP_LOCATION="both";; # [cite: 16]
        i) INCREMENTAL=true;; # [cite: 16]
        t) BACKUP_TYPE="$OPTARG";; # [cite: 16]
        q) QUIET=true;; # [cite: 16]
        n) NAME_SUFFIX="$OPTARG";;
        v) VERBOSE=true;; # [cite: 16]
        \?) # [cite: 17]
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-t <type>] [-q] [-n <suffix>] [-v]" >&2 # [cite: 17]
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)" # [cite: 17]
            echo -e "  -f: Override compression format (zip, tar.gz, tar)" # [cite: 17]
            echo -e "  -d: Dry run (no actual changes)" # [cite: 17]
            echo -e "  -l: Store backup locally only" # [cite: 18]
            echo -e "  -r: Store backup remotely only" # [cite: 18]
            echo -e "  -b: Store backup both locally and remotely" # [cite: 18]
            echo -e "  -i: Use incremental backup for files" # [cite: 18]
            echo -e "  -t: Backup type (full, db, files)" # [cite: 18]
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" # [cite: 19]
            echo -e "  -n: Custom suffix for backup filenames (e.g., 'projectX-final')"
            echo -e "  -v: Verbose output" # [cite: 19]
            exit 1
            ;;
    esac
done

# --- Interactive prompt for NAME_SUFFIX if not provided via -n and not in QUIET mode ---
if [ -z "$NAME_SUFFIX" ] && [ "${QUIET}" = false ]; then
    echo -e "${YELLOW}Do you want to add a custom suffix to the backup filenames? (y/N):${NC}"
    read -r -p "> " confirm_suffix
    if [[ "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Enter custom suffix (e.g., 'before-major-update', 'staging-backup'):${NC}"
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
    # Sanitize suffix if provided via -n
    ORIGINAL_CMD_SUFFIX="$NAME_SUFFIX"
    NAME_SUFFIX=$(sanitize_filename_suffix "$NAME_SUFFIX")
    if [ -z "$NAME_SUFFIX" ] && [ -n "$ORIGINAL_CMD_SUFFIX" ]; then # If suffix became empty
         echo -e "${YELLOW}Warning: Provided suffix '${ORIGINAL_CMD_SUFFIX}' was invalid or became empty after sanitization. Proceeding without a custom suffix.${NC}"
    elif [ "$NAME_SUFFIX" != "$ORIGINAL_CMD_SUFFIX" ]; then
        echo -e "${YELLOW}Sanitized command-line suffix: '${ORIGINAL_CMD_SUFFIX}' -> '${NAME_SUFFIX}'${NC}"
    fi
fi

# Initialize log (after QUIET is potentially set and suffix handled)
init_log "WordPress Backup" # [cite: 20]

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then # [cite: 20]
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}" # [cite: 20]
    if ! select_config_file "$SCRIPTPATH/configs" "backup"; then # [cite: 21]
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2 # [cite: 21]
        exit 1
    fi
fi
process_config_file "$CONFIG_FILE" "Backup" # [cite: 21]

# Validate required configuration variables
for var in wpPath; do # [cite: 21]
    if [ -z "${!var}" ]; then # [cite: 22]
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2 # [cite: 22]
        exit 1
    fi
done

# --- Define backup directories and final filenames ---
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}" # [cite: 22]
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}" # [cite: 22]
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}" # [cite: 22]

BACKUP_LOCATION="${CLI_BACKUP_LOCATION:-${BACKUP_LOCATION:-remote}}" # [cite: 22]

DEST="$BACKUP_DIR/$DIR" # [cite: 22]
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}" # [cite: 22]
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}" # [cite: 22]
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}" # [cite: 22]
NICE_LEVEL="${NICE_LEVEL:-19}" #
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}" # [cite: 22]
LOG_LEVEL="${VERBOSE:+verbose}" # [cite: 22]
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}" # [cite: 22]

FORMATTED_SUFFIX=""
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi

DB_FILENAME="${DB_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}" # [cite: 22]
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}" # [cite: 22]

# SSH Variables Check for remote backup
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 22]
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do # [cite: 23]
        if [ -z "${!var}" ]; then # [cite: 24]
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in $CONFIG_FILE for remote backup!${NC}" >&2 # [cite: 25]
            exit 1
        fi
    done
fi

# Prepare EXCLUDE_ARGS for rsync
EXCLUDE_ARGS="" #
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS" # [cite: 25]
for pattern in "${PATTERNS[@]}"; do # [cite: 25]
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude '$pattern'" # [cite: 26]
done

# Cleanup function trap
cleanup_backup() {
    cleanup "Backup process" "Backup" #
    rm -rf "$DEST" #
}
trap cleanup_backup INT TERM #

# --- Main Backup Logic ---
if ! $QUIET; then
    echo -e "${CYAN}Starting backup process...${NC}"
    echo -e "${INFO}Backup type: ${BOLD}$BACKUP_TYPE${NC}"
    echo -e "${INFO}Backup location: ${BOLD}$BACKUP_LOCATION${NC}"
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${INFO}Filename suffix: ${BOLD}${NAME_SUFFIX}${NC}"
    fi
    if [ "$INCREMENTAL" = true ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; }; then
        echo -e "${INFO}Incremental file backup: ${BOLD}Enabled${NC}"
    fi
fi

log "INFO" "Starting backup process for $DIR to $BACKUP_LOCATION (Incremental Files: $INCREMENTAL, Type: $BACKUP_TYPE, Suffix: $NAME_SUFFIX)" #
update_status "STARTED" "Backup process for $DIR to $BACKUP_LOCATION" #

# Validate SSH if needed
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 26]
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Backup" # [cite: 27]
    log "INFO" "SSH connection validated successfully" # [cite: 27]
fi

# Create directories
if [ "$DRY_RUN" = false ]; then # [cite: 27]
    mkdir -pv "$BACKUP_DIR" # [cite: 28]
    check_status $? "Creating backups directory" "Backup" # [cite: 28, 29]
    mkdir -pv "$DEST" # [cite: 29]
    check_status $? "Creating destination directory" "Backup" # [cite: 29, 30]
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then # [cite: 30]
        mkdir -pv "$LOCAL_BACKUP_DIR" # [cite: 31]
        check_status $? "Creating local backups directory" "Backup" # [cite: 31, 32]
    fi
else
    log "INFO" "Dry run: Skipping directory creation" #
fi

# Incremental backup setup
LAST_BACKUP="" #
if [ "$INCREMENTAL" = true ] && [ -f "$LAST_BACKUP_FILE" ]; then # [cite: 32]
    LAST_BACKUP=$(cat "$LAST_BACKUP_FILE") # [cite: 33]
    log "INFO" "Using last backup as reference for incremental files: $LAST_BACKUP" # [cite: 33]
elif [ "$INCREMENTAL" = true ]; then # [cite: 33]
    log "WARNING" "No previous backup found, falling back to full files backup" # [cite: 34]
    INCREMENTAL=false # [cite: 34]
fi

# Database Backup
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then # [cite: 34]
    if [ "$DRY_RUN" = false ]; then # [cite: 35]
        mkdir -pv "$DEST/DB" # [cite: 36]
        check_status $? "Creating DB directory" "Backup" # [cite: 36, 37]
        cd "$DEST/DB" || exit 1 # [cite: 37]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Exporting database...${NC}"; fi # [cite: 38]
        wp_cli db export --add-drop-table --path="$wpPath" # [cite: 38]
        check_status $? "Full database export" "Backup" # [cite: 38, 39]
        cd "$DEST" || exit 1 # [cite: 39]
        log "DEBUG" "Starting database compression" # [cite: 40]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing database...${NC}"; fi # [cite: 40]
        (compress "DB/" "$DB_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv DB/) & # [cite: 40]
        DB_PID=$! # [cite: 40]
    else
        log "INFO" "Dry run: Skipping database backup" # [cite: 41]
    fi
fi

# Files Backup
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then # [cite: 41]
    if [ "$DRY_RUN" = false ]; then # [cite: 42]
        mkdir -pv "$DEST/Files" # [cite: 43]
        check_status $? "Creating Files directory" "Backup" # [cite: 43, 44]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Backing up files...${NC}"; fi # [cite: 44]
        if [ "$INCREMENTAL" = true ] && [ -n "$LAST_BACKUP" ]; then # [cite: 44]
            # Ensure LAST_BACKUP directory exists before using it with --link-dest
            if [ -d "$LAST_BACKUP/Files" ]; then
                eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS --link-dest=\"$LAST_BACKUP/Files\" \"$wpPath/\" \"$DEST/Files\"" # [cite: 45]
                check_status $? "Incremental files backup with rsync" "Backup" # [cite: 45, 46]
            else
                log "WARNING" "Last backup files directory '$LAST_BACKUP/Files' not found. Performing full files backup instead."
                eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS \"$wpPath/\" \"$DEST/Files\"" # [cite: 46]
                check_status $? "Full files backup with rsync (fallback from incremental)" "Backup" # [cite: 46, 47]
            fi
        else
            eval "nice -n \"$NICE_LEVEL\" rsync -av --progress --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS \"$wpPath/\" \"$DEST/Files\"" # [cite: 46]
            check_status $? "Full files backup with rsync" "Backup" # [cite: 46, 47]
        fi
        cd "$DEST" || exit 1 # [cite: 47]
        log "DEBUG" "Starting files compression" # [cite: 48]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing files...${NC}"; fi # [cite: 48]
        (compress "Files/" "$FILES_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv Files/) & # [cite: 48]
        FILES_PID=$! # [cite: 48]
    else
        log "INFO" "Dry run: Skipping files backup" # [cite: 49]
    fi
fi

# Wait for compression and cleanup
if [ "$DRY_RUN" = false ]; then # [cite: 49]
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then # [cite: 50]
        wait $DB_PID # [cite: 51]
        check_status $? "Database compression and cleanup" "Backup" # [cite: 51, 52]
        log "INFO" "Database backup completed: $DEST/$DB_FILENAME" # [cite: 52]
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then # [cite: 52]
        wait $FILES_PID # [cite: 53]
        check_status $? "Files compression and cleanup" "Backup" # [cite: 53, 54]
        log "INFO" "Files backup completed: $DEST/$FILES_FILENAME" # [cite: 54]
    fi
fi

# Copy to local storage if specified
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; }; then # [cite: 54]
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying backups to local storage...${NC}"; fi # [cite: 55]

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then # [cite: 55]
        cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/" # [cite: 56]
        check_status $? "Copying database backup to local storage" "Backup" # [cite: 56, 57]
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then # [cite: 57]
        cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/" # [cite: 58]
        check_status $? "Copying files backup to local storage" "Backup" # [cite: 58, 59]
    fi
    log "INFO" "Backups copied to local storage: $LOCAL_BACKUP_DIR" # [cite: 59]
fi

# Transfer to remote storage if specified
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; }; then # [cite: 59]
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Transferring backups to remote storage...${NC}"; fi # [cite: 60]

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then # [cite: 60]
        nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$DB_FILENAME" "$destinationUser@$destinationIP:$destinationDbBackupPath" # [cite: 61]
        check_status $? "Transferring database backup to remote storage" "Backup" # [cite: 61, 62]
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then # [cite: 62]
        nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$FILES_FILENAME" "$destinationUser@$destinationIP:$destinationFilesBackupPath" # [cite: 63]
        check_status $? "Transferring files backup to remote storage" "Backup" # [cite: 63, 64]
    fi
    log "INFO" "Backups transferred to remote storage" # [cite: 64]
fi

# Save last backup path for incremental if files were backed up
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; }; then # [cite: 64]
    echo "$DEST" > "$LAST_BACKUP_FILE" # [cite: 65]
    log "INFO" "Saved current backup path for future incremental backups: $DEST" # [cite: 65]
fi

# Cleanup temporary files if only remote backup
if [ "$DRY_RUN" = false ]; then # [cite: 65]
    if [ "$BACKUP_LOCATION" = "remote" ]; then # [cite: 66]
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up local temporary files...${NC}"; fi # [cite: 67]
        rm -rf "$DEST" # [cite: 67]
        check_status $? "Cleaning up local temporary files" "Backup" # [cite: 67, 68]
    fi
fi

# --- Finalization ---
END_TIME=$(date +%s) #
DURATION=$((END_TIME - START_TIME)) #
FORMATTED_DURATION=$(format_duration $DURATION) #
log "INFO" "Backup process completed successfully in ${FORMATTED_DURATION}" #
update_status "SUCCESS" "Backup process for $DIR completed in ${FORMATTED_DURATION}" #

notify "SUCCESS" "Backup process for $DIR completed successfully to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Backup" #

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Backup process completed successfully!${NC}" #
    echo -e "${GREEN}Backup location: ${NC}${BOLD}${BACKUP_LOCATION}${NC}" #
    echo -e "${GREEN}Backup type: ${NC}${BOLD}${BACKUP_TYPE}${NC}" #
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom suffix: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}" #

    FINAL_DB_PATH=""
    FINAL_FILES_PATH=""

    case "$BACKUP_LOCATION" in
        "local")
            FINAL_DB_PATH="$LOCAL_BACKUP_DIR/$DB_FILENAME"
            FINAL_FILES_PATH="$LOCAL_BACKUP_DIR/$FILES_FILENAME"
            ;;
        "both")
            FINAL_DB_PATH="$LOCAL_BACKUP_DIR/$DB_FILENAME (and remote)"
            FINAL_FILES_PATH="$LOCAL_BACKUP_DIR/$FILES_FILENAME (and remote)"
            ;;
        "remote")
            # For remote-only, DEST was cleaned up, so refer to the intended remote path for info
            # However, DB_FILENAME and FILES_FILENAME are correct names
            FINAL_DB_PATH="$destinationUser@$destinationIP:$destinationDbBackupPath/$DB_FILENAME"
            FINAL_FILES_PATH="$destinationUser@$destinationIP:$destinationFilesBackupPath/$FILES_FILENAME"
            ;;
    esac
    
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then # [cite: 68]
        if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
             if [ -f "$LOCAL_BACKUP_DIR/$DB_FILENAME" ]; then
                DB_SIZE=$(du -h "$LOCAL_BACKUP_DIR/$DB_FILENAME" | cut -f1) #
                echo -e "${GREEN}Database backup: ${NC}$LOCAL_BACKUP_DIR/$DB_FILENAME (${DB_SIZE})"
             fi
        elif [ "$BACKUP_LOCATION" = "remote" ] && [ -f "$DEST/$DB_FILENAME" ]; then # Should not happen if cleanup occurred
             DB_SIZE=$(du -h "$DEST/$DB_FILENAME" | cut -f1) # [cite: 70]
             echo -e "${GREEN}Database backup size (before remote cleanup): ${NC}${DB_SIZE}${NC}" # [cite: 70]
        elif [ "$BACKUP_LOCATION" = "remote" ]; then
             echo -e "${GREEN}Database backup: ${NC}$FINAL_DB_PATH"
        fi
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then # [cite: 71]
         if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
             if [ -f "$LOCAL_BACKUP_DIR/$FILES_FILENAME" ]; then
                FILES_SIZE=$(du -h "$LOCAL_BACKUP_DIR/$FILES_FILENAME" | cut -f1) #
                echo -e "${GREEN}Files backup: ${NC}$LOCAL_BACKUP_DIR/$FILES_FILENAME (${FILES_SIZE})"
             fi
        elif [ "$BACKUP_LOCATION" = "remote" ] && [ -f "$DEST/$FILES_FILENAME" ]; then # Should not happen
             FILES_SIZE=$(du -h "$DEST/$FILES_FILENAME" | cut -f1) # [cite: 72]
             echo -e "${GREEN}Files backup size (before remote cleanup): ${NC}${FILES_SIZE}${NC}" # [cite: 72]
        elif [ "$BACKUP_LOCATION" = "remote" ]; then
             echo -e "${GREEN}Files backup: ${NC}$FINAL_FILES_PATH"
        fi
    fi
fi