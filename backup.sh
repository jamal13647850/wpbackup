#!/bin/bash
#
# Script: backup.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Performs WordPress backup (database and/or files) with various options.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/backup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/backup_status.log}"
LAST_BACKUP_FILE="$SCRIPTPATH/logs/last_backup.txt" # Stores path of the last successful files backup for incremental

# --- Default values for options ---
DRY_RUN=false
CLI_BACKUP_LOCATION=""  # Stores command-line specified backup location (local, remote, both)
VERBOSE=false
QUIET=false             # Suppress non-essential output and interactive prompts
INCREMENTAL=false       # Perform incremental file backup
BACKUP_TYPE="full"      # Type of backup (full, db, files)
NAME_SUFFIX=""          # Custom suffix for backup filenames

# Parse command line options
while getopts "c:f:dlrbit:qn:v" opt; do # Added 'n:' for name_suffix and 'q' for quiet
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";; # Override compression format
        d) DRY_RUN=true;;
        l) CLI_BACKUP_LOCATION="local";;  # Backup locally only
        r) CLI_BACKUP_LOCATION="remote";; # Backup remotely only
        b) CLI_BACKUP_LOCATION="both";;   # Backup locally and remotely
        i) INCREMENTAL=true;;
        t) BACKUP_TYPE="$OPTARG";;
        q) QUIET=true;;
        n) NAME_SUFFIX="$OPTARG";;
        v) VERBOSE=true;;
        \?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-t <type>] [-q] [-n <suffix>] [-v]" >&2
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)" >&2
            echo -e "  -f: Override compression format (zip, tar.gz, tar)" >&2
            echo -e "  -d: Dry run (no actual changes)" >&2
            echo -e "  -l: Store backup locally only" >&2
            echo -e "  -r: Store backup remotely only" >&2
            echo -e "  -b: Store backup both locally and remotely" >&2
            echo -e "  -i: Use incremental backup for files" >&2
            echo -e "  -t: Backup type (full, db, files)" >&2
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" >&2
            echo -e "  -n: Custom suffix for backup filenames (e.g., 'projectX-final')" >&2
            echo -e "  -v: Verbose output" >&2
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
            NAME_SUFFIX=$(sanitize_filename_suffix "$interactive_suffix") # Sanitize the input
            if [ -n "$NAME_SUFFIX" ]; then
                 echo -e "${GREEN}Using sanitized suffix: '${NAME_SUFFIX}'${NC}"
            else
                 echo -e "${YELLOW}No valid suffix provided or suffix became empty after sanitization. Proceeding without a custom suffix.${NC}"
            fi
        else
            echo -e "${YELLOW}No suffix entered. Proceeding without a custom suffix.${NC}"
        fi
    else
        echo -e "${INFO}Proceeding without a custom suffix.${NC}" # Using ${INFO} for consistency if defined in common.sh
    fi
elif [ -n "$NAME_SUFFIX" ]; then
    # Sanitize suffix if provided via -n command-line argument
    ORIGINAL_CMD_SUFFIX="$NAME_SUFFIX"
    NAME_SUFFIX=$(sanitize_filename_suffix "$NAME_SUFFIX")
    if [ -z "$NAME_SUFFIX" ] && [ -n "$ORIGINAL_CMD_SUFFIX" ]; then # If suffix became empty after sanitization
         echo -e "${YELLOW}Warning: Provided suffix '${ORIGINAL_CMD_SUFFIX}' was invalid or became empty after sanitization. Proceeding without a custom suffix.${NC}"
    elif [ "$NAME_SUFFIX" != "$ORIGINAL_CMD_SUFFIX" ] && [ "${QUIET}" = false ] ; then # Notify only if changed and not quiet
        echo -e "${YELLOW}Sanitized command-line suffix: '${ORIGINAL_CMD_SUFFIX}' -> '${NAME_SUFFIX}'${NC}"
    fi
fi

# Initialize log (after QUIET is potentially set and suffix handled)
init_log "WordPress Backup"

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "backup"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
fi
process_config_file "$CONFIG_FILE" "Backup" # This sources the config file

# Validate required configuration variables from the config file
for var in wpPath; do # Add other essential vars here if needed
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable '$var' is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# --- Define backup directories and final filenames ---
DIR="${DIR:-$(date +%Y%m%d-%H%M%S)}" # Backup directory name, defaults to current timestamp
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}" # Main temporary backup staging area
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}" # Final local storage for backups

# Determine backup location: CLI option > config file > default (remote)
BACKUP_LOCATION="${CLI_BACKUP_LOCATION:-${BACKUP_LOCATION:-remote}}"

DEST="$BACKUP_DIR/$DIR" # Full path to the current backup's staging directory
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-zip}}" # CLI format > config format > default (zip)
NICE_LEVEL="${NICE_LEVEL:-19}" # CPU niceness for intensive operations
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache}" # Default rsync exclude patterns
LOG_LEVEL="${VERBOSE:+verbose}" # Set log level based on verbosity
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"

FORMATTED_SUFFIX="" # Prepare the suffix part for filenames
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi

DB_FILENAME="${DB_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}"
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}"

# SSH Variables Check for remote backup location
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable '$var' is not set in $CONFIG_FILE for remote backup!${NC}" >&2
            exit 1
        fi
    done
fi

# Prepare EXCLUDE_ARGS for rsync from comma-separated string
EXCLUDE_ARGS=""
IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'" # Single quotes to handle patterns with spaces, etc.
done

# Cleanup function trap: ensures temporary files/directories are removed on exit/interrupt
cleanup_backup() {
    cleanup "Backup process" "Backup" # Call common cleanup
    if [ -d "$DEST" ]; then # Only remove $DEST if it was created
      log "INFO" "Cleaning up temporary backup directory: $DEST"
      rm -rf "$DEST"
    fi
}
trap cleanup_backup EXIT INT TERM # Added EXIT trap for more robust cleanup

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

log "INFO" "Starting backup (Type: $BACKUP_TYPE, Location: $BACKUP_LOCATION, Suffix: '$NAME_SUFFIX', Incremental: $INCREMENTAL) for $DIR"
update_status "STARTED" "Backup process for $DIR to $BACKUP_LOCATION"

# Validate SSH connection if remote backup is involved
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Backup"
    # validate_ssh should exit on failure, so no need to check $? here if it's designed that way.
    log "INFO" "SSH connection validated successfully"
fi

# Create necessary directories
if [ "$DRY_RUN" = false ]; then
    mkdir -pv "$BACKUP_DIR" # Main staging parent
    check_status $? "Creating main backup directory $BACKUP_DIR" "Backup"
    mkdir -pv "$DEST" # Specific staging for this backup instance
    check_status $? "Creating destination staging directory $DEST" "Backup"
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR" # Final local storage
        check_status $? "Creating local backups directory $LOCAL_BACKUP_DIR" "Backup"
    fi
else
    log "INFO" "Dry run: Skipping directory creation."
fi

# Incremental backup setup: determine path to the last backup for rsync --link-dest
LAST_BACKUP_FILES_PATH=""
if [ "$INCREMENTAL" = true ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; }; then
    if [ -f "$LAST_BACKUP_FILE" ] && [ -s "$LAST_BACKUP_FILE" ]; then # Check if file exists and is not empty
        # Assuming LAST_BACKUP_FILE stores the path to the root of the previous backup's Files directory (e.g., .../backups/YYYYMMDD-HHMMSS/Files)
        # Or it could store the root of the backup instance (e.g., .../backups/YYYYMMDD-HHMMSS)
        # For rsync --link-dest, we need the path to the *source* of the previous files, typically $PREVIOUS_DEST/Files
        PREVIOUS_BACKUP_INSTANCE_ROOT=$(cat "$LAST_BACKUP_FILE")
        LAST_BACKUP_FILES_PATH="$PREVIOUS_BACKUP_INSTANCE_ROOT/Files" # Assuming structure $ROOT/Files

        if [ -d "$LAST_BACKUP_FILES_PATH" ]; then
            log "INFO" "Using last backup files at '$LAST_BACKUP_FILES_PATH' as reference for incremental."
        else
            log "WARNING" "Last backup files path '$LAST_BACKUP_FILES_PATH' not found. Falling back to full files backup."
            INCREMENTAL=false # Disable incremental if previous path is invalid
            LAST_BACKUP_FILES_PATH=""
        fi
    else
        log "WARNING" "No previous backup reference found ($LAST_BACKUP_FILE is missing or empty). Falling back to full files backup."
        INCREMENTAL=false # Disable incremental if no reference
    fi
fi


# --- Database Backup ---
DB_PID=""
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
    if [ "$DRY_RUN" = false ]; then
        mkdir -pv "$DEST/DB"
        check_status $? "Creating DB staging directory $DEST/DB" "Backup"
        
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Exporting database...${NC}"; fi
        # It's safer to export to a file directly in $DEST/DB
        wp_cli db export "$DEST/DB/database.sql" --add-drop-table --path="$wpPath"
        check_status $? "Database export to $DEST/DB/database.sql" "Backup"
        
        if [ -f "$DEST/DB/database.sql" ]; then
            log "DEBUG" "Starting database compression for $DB_FILENAME"
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing database...${NC}"; fi
            # Compress the contents of DB/ into $DEST/$DB_FILENAME, then remove DB/
            (cd "$DEST" && compress "DB/" "$DB_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv DB/) &
            DB_PID=$!
        else
            log "ERROR" "Database SQL export file not found at $DEST/DB/database.sql. Skipping DB compression."
            update_status "FAILURE" "Database SQL export failed" # Or a more specific status
        fi
    else
        log "INFO" "Dry run: Skipping database backup."
        if ! $QUIET; then echo -e "${INFO}${BOLD}[Dry Run] Would export and compress database.${NC}"; fi
    fi
fi

# --- Files Backup ---
FILES_PID=""
if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
    if [ "$DRY_RUN" = false ]; then
        mkdir -pv "$DEST/Files"
        check_status $? "Creating Files staging directory $DEST/Files" "Backup"
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Backing up files...${NC}"; fi

        RSYNC_CMD="nice -n \"$NICE_LEVEL\" rsync -av --progress --delete --max-size=\"${maxSize:-50m}\" $EXCLUDE_ARGS"
        if [ "$INCREMENTAL" = true ] && [ -n "$LAST_BACKUP_FILES_PATH" ] && [ -d "$LAST_BACKUP_FILES_PATH" ]; then
            # For incremental, source is wpPath, dest is $DEST/Files, link-dest is previous Files dir
            log "INFO" "Performing incremental files backup using --link-dest='$LAST_BACKUP_FILES_PATH'"
            RSYNC_CMD="$RSYNC_CMD --link-dest=\"$LAST_BACKUP_FILES_PATH\" \"$wpPath/\" \"$DEST/Files/\""
        else
            if [ "$INCREMENTAL" = true ]; then # Log if it was intended but couldn't run
                 log "INFO" "Performing full files backup (incremental conditions not met)."
            else
                 log "INFO" "Performing full files backup."
            fi
            RSYNC_CMD="$RSYNC_CMD \"$wpPath/\" \"$DEST/Files/\""
        fi
        
        eval "$RSYNC_CMD" # Using eval because EXCLUDE_ARGS contains quoted arguments
        check_status $? "Files backup with rsync ($([ "$INCREMENTAL" = true ] && echo "incremental" || echo "full"))" "Backup"
        
        log "DEBUG" "Starting files compression for $FILES_FILENAME"
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing files...${NC}"; fi
        # Compress the contents of Files/ into $DEST/$FILES_FILENAME, then remove Files/
        (cd "$DEST" && compress "Files/" "$FILES_FILENAME" && nice -n "$NICE_LEVEL" rm -rfv Files/) &
        FILES_PID=$!
    else
        log "INFO" "Dry run: Skipping files backup."
        if ! $QUIET; then echo -e "${INFO}${BOLD}[Dry Run] Would rsync and compress files.${NC}"; fi
    fi
fi

# Wait for compression and cleanup of source folders
if [ "$DRY_RUN" = false ]; then
    if [ -n "$DB_PID" ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; }; then
        wait $DB_PID
        check_status $? "Database compression and source cleanup" "Backup"
        if [ -f "$DEST/$DB_FILENAME" ]; then
            log "INFO" "Database backup compressed: $DEST/$DB_FILENAME"
        else
            log "ERROR" "Database backup file $DEST/$DB_FILENAME not found after compression."
        fi
    fi

    if [ -n "$FILES_PID" ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; }; then
        wait $FILES_PID
        check_status $? "Files compression and source cleanup" "Backup"
         if [ -f "$DEST/$FILES_FILENAME" ]; then
            log "INFO" "Files backup compressed: $DEST/$FILES_FILENAME"
        else
            log "ERROR" "Files backup file $DEST/$FILES_FILENAME not found after compression."
        fi
    fi
fi

# Copy to local storage if specified
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; }; then
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying backups to local storage: $LOCAL_BACKUP_DIR ${NC}"; fi
    COPIED_TO_LOCAL=false
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
        if [ -f "$DEST/$DB_FILENAME" ]; then
            cp -v "$DEST/$DB_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying database backup to $LOCAL_BACKUP_DIR" "Backup" && COPIED_TO_LOCAL=true
        else
            log "ERROR" "DB backup file $DEST/$DB_FILENAME not found for local copy."
        fi
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
         if [ -f "$DEST/$FILES_FILENAME" ]; then
            cp -v "$DEST/$FILES_FILENAME" "$LOCAL_BACKUP_DIR/"
            check_status $? "Copying files backup to $LOCAL_BACKUP_DIR" "Backup" && COPIED_TO_LOCAL=true
        else
            log "ERROR" "Files backup file $DEST/$FILES_FILENAME not found for local copy."
        fi
    fi
    [ "$COPIED_TO_LOCAL" = true ] && log "INFO" "Backups copied to local storage: $LOCAL_BACKUP_DIR"
fi

# Transfer to remote storage if specified
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; }; then
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Transferring backups to remote storage...${NC}"; fi
    TRANSFERRED_TO_REMOTE=false
    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
        if [ -f "$DEST/$DB_FILENAME" ]; then
            nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$DB_FILENAME" "$destinationUser@$destinationIP:$destinationDbBackupPath"
            check_status $? "Transferring database backup to remote" "Backup" && TRANSFERRED_TO_REMOTE=true
        else
            log "ERROR" "DB backup file $DEST/$DB_FILENAME not found for remote transfer."
        fi
    fi

    if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
        if [ -f "$DEST/$FILES_FILENAME" ]; then
            nice -n "$NICE_LEVEL" scp -P "$destinationPort" -i "$privateKeyPath" "$DEST/$FILES_FILENAME" "$destinationUser@$destinationIP:$destinationFilesBackupPath"
            check_status $? "Transferring files backup to remote" "Backup" && TRANSFERRED_TO_REMOTE=true
        else
            log "ERROR" "Files backup file $DEST/$FILES_FILENAME not found for remote transfer."
        fi
    fi
    [ "$TRANSFERRED_TO_REMOTE" = true ] && log "INFO" "Backups transferred to remote storage."
fi

# Save last backup *instance root* path for incremental if files were backed up successfully.
# This should be the $DEST path, which contains the /Files subdirectory used by rsync.
if [ "$DRY_RUN" = false ] && { [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; }; then
    # Only update if files backup was successful (check if $DEST/$FILES_FILENAME exists)
    if [ -f "$DEST/$FILES_FILENAME" ]; then
        echo "$DEST" > "$LAST_BACKUP_FILE" # Save the root of the current backup instance
        log "INFO" "Saved current backup instance path '$DEST' to $LAST_BACKUP_FILE for future incremental backups."
    else
        log "WARNING" "Files backup artifact $DEST/$FILES_FILENAME not found. Not updating $LAST_BACKUP_FILE."
    fi
fi

# Cleanup temporary files ($DEST) if backup was only remote and successfully transferred, or if it's not 'both'.
# The main `trap cleanup_backup EXIT` will handle $DEST removal if script exits for any reason.
# This specific cleanup is for when backup location is *only* remote.
if [ "$DRY_RUN" = false ]; then
    if [ "$BACKUP_LOCATION" = "remote" ]; then # Only remote, not local, not both
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up local temporary staging files from $DEST...${NC}"; fi
        rm -rf "$DEST" # This is now handled by the EXIT trap. Can be removed or kept for explicit logging.
        # check_status $? "Cleaning up local temporary staging files from $DEST" "Backup" # Also handled by trap.
        log "INFO" "Local temporary staging directory $DEST cleaned up for remote-only backup."
    fi
fi

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME)) # START_TIME should be defined in common.sh
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Backup process for $DIR completed successfully in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Backup process for $DIR (Type: $BACKUP_TYPE) completed in ${FORMATTED_DURATION}"

# Send notification
if [ "${NOTIFY_ON_SUCCESS:-true}" = true ]; then # Assuming NOTIFY_ON_SUCCESS is a var from common.sh or config
    notify "SUCCESS" "Backup of $wpHost ($DIR, Type: $BACKUP_TYPE) completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}" "Backup"
fi

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Backup process completed successfully!${NC}"
    echo -e "${GREEN}Backup location(s): ${NC}${BOLD}${BACKUP_LOCATION}${NC}"
    echo -e "${GREEN}Backup type: ${NC}${BOLD}${BACKUP_TYPE}${NC}"
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom suffix: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}"

    # Display final paths and sizes (if not dry run)
    if [ "$DRY_RUN" = false ]; then
        FINAL_DB_PATH_INFO=""
        FINAL_FILES_PATH_INFO=""

        if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "db" ]; then
            DB_PATH_TO_CHECK=""
            if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
                DB_PATH_TO_CHECK="$LOCAL_BACKUP_DIR/$DB_FILENAME"
            elif [ "$BACKUP_LOCATION" = "remote" ]; then
                # For remote, we don't have local size after cleanup by trap. Info is enough.
                FINAL_DB_PATH_INFO="$destinationUser@$destinationIP:$destinationDbBackupPath/$DB_FILENAME"
            fi
            if [ -n "$DB_PATH_TO_CHECK" ] && [ -f "$DB_PATH_TO_CHECK" ]; then
                DB_SIZE=$(du -h "$DB_PATH_TO_CHECK" | cut -f1)
                FINAL_DB_PATH_INFO="$DB_PATH_TO_CHECK (${DB_SIZE})"
            elif [ -z "$FINAL_DB_PATH_INFO" ] ; then # If not remote and not found locally
                 FINAL_DB_PATH_INFO="Not found or not created."
            fi
            echo -e "${GREEN}Database backup: ${NC}$FINAL_DB_PATH_INFO"
        fi

        if [ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "files" ]; then
            FILES_PATH_TO_CHECK=""
             if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
                FILES_PATH_TO_CHECK="$LOCAL_BACKUP_DIR/$FILES_FILENAME"
            elif [ "$BACKUP_LOCATION" = "remote" ]; then
                FINAL_FILES_PATH_INFO="$destinationUser@$destinationIP:$destinationFilesBackupPath/$FILES_FILENAME"
            fi

            if [ -n "$FILES_PATH_TO_CHECK" ] && [ -f "$FILES_PATH_TO_CHECK" ]; then
                FILES_SIZE=$(du -h "$FILES_PATH_TO_CHECK" | cut -f1)
                FINAL_FILES_PATH_INFO="$FILES_PATH_TO_CHECK (${FILES_SIZE})"
            elif [ -z "$FINAL_FILES_PATH_INFO" ] ; then
                FINAL_FILES_PATH_INFO="Not found or not created."
            fi
            echo -e "${GREEN}Files backup: ${NC}$FINAL_FILES_PATH_INFO"
        fi
    else
        echo -e "${INFO}${BOLD}[Dry Run] No files were actually created or transferred.${NC}"
    fi
fi
# The EXIT trap will handle final cleanup of $DEST
exit 0