#!/bin/bash
#
# Script: files.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Performs WordPress files backup with options for incremental, local/remote storage, and custom naming.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/files.log" # Log file for this script
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/files_status.log}" # Status log for this script

# --- Default values for options ---
DRY_RUN=false
VERBOSE=false
QUIET=false               # Suppress non-essential output
BACKUP_LOCATION=""        # CLI override for backup location (local, remote, both); config is default
INCREMENTAL=false         # Perform incremental file backup
NAME_SUFFIX=""            # Optional custom suffix for the backup filename

# Parse command line options
while getopts "c:f:dlrbiqn:v" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";; # Override compression format
        d) DRY_RUN=true;;
        l) BACKUP_LOCATION="local";;
        r) BACKUP_LOCATION="remote";;
        b) BACKUP_LOCATION="both";;
        i) INCREMENTAL=true;;
        q) QUIET=true;;
        n) NAME_SUFFIX="$OPTARG";;
        v) VERBOSE=true;;
        \?) # Handle invalid options
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-q] [-n <suffix>] [-v]" >&2
            echo -e "  -c: Configuration file (can be .conf.gpg or .conf)" >&2
            echo -e "  -f: Override compression format (e.g., zip, tar.gz, tar)" >&2
            echo -e "  -d: Dry run (simulate changes, no actual backup)" >&2
            echo -e "  -l: Store backup locally only" >&2
            echo -e "  -r: Store backup remotely only" >&2
            echo -e "  -b: Store backup both locally and remotely" >&2
            echo -e "  -i: Use incremental backup for files" >&2
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" >&2
            echo -e "  -n: Custom suffix for backup filename (e.g., 'files-pre-deploy')" >&2
            echo -e "  -v: Verbose output" >&2
            exit 1
            ;;
    esac
done

# --- Interactive prompt for NAME_SUFFIX if not provided via -n and not in QUIET mode ---
if [ -z "$NAME_SUFFIX" ] && [ "${QUIET}" = false ]; then
    echo -e "${YELLOW}Do you want to add a custom suffix to the files backup filename? (y/N):${NC}"
    read -r -p "> " confirm_suffix
    if [[ "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Enter custom suffix (e.g., 'before-major-update'):${NC}"
        read -r -p "> " interactive_suffix
        if [ -n "$interactive_suffix" ]; then
            NAME_SUFFIX=$(sanitize_filename_suffix "$interactive_suffix") # Sanitize using common.sh function
            if [ -n "$NAME_SUFFIX" ]; then
                 echo -e "${GREEN}Using sanitized suffix: '${NAME_SUFFIX}'${NC}"
            else
                 echo -e "${YELLOW}No valid suffix derived after sanitization. Proceeding without a custom suffix.${NC}"
            fi
        else
            echo -e "${YELLOW}No suffix entered. Proceeding without a custom suffix.${NC}"
        fi
    else
        if ! $QUIET; then # Only print if not quiet
             echo -e "${INFO}Proceeding without a custom suffix.${NC}" # INFO color from common.sh
        fi
    fi
elif [ -n "$NAME_SUFFIX" ]; then
    # Sanitize suffix if provided via -n argument
    ORIGINAL_CMD_SUFFIX="$NAME_SUFFIX"
    NAME_SUFFIX=$(sanitize_filename_suffix "$NAME_SUFFIX")
    if [ -z "$NAME_SUFFIX" ] && [ -n "$ORIGINAL_CMD_SUFFIX" ]; then
         if ! $QUIET; then echo -e "${YELLOW}Warning: Provided suffix '${ORIGINAL_CMD_SUFFIX}' was invalid or became empty after sanitization. Proceeding without a custom suffix.${NC}"; fi
         log "WARNING" "Provided suffix '${ORIGINAL_CMD_SUFFIX}' sanitized to empty. No suffix will be used."
    elif [ "$NAME_SUFFIX" != "$ORIGINAL_CMD_SUFFIX" ] && [ -n "$NAME_SUFFIX" ] && ! $QUIET; then
        echo -e "${YELLOW}Sanitized command-line suffix: '${ORIGINAL_CMD_SUFFIX}' -> '${NAME_SUFFIX}'${NC}"
    fi
fi

init_log "WordPress Files Backup" # Initialize logging for this script

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "files backup"; then # Interactive selection
        log "ERROR" "Configuration file selection failed or was cancelled."
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then # Ensure specified config file exists
    log "ERROR" "Configuration file '$CONFIG_FILE' not found."
    exit 1
fi
process_config_file "$CONFIG_FILE" "Files Backup" # Load and source the config

# Validate required configuration variables from config file
for var in wpPath; do # wpPath is essential for knowing what to back up
    if [ -z "${!var}" ]; then
        log "ERROR" "Required variable '$var' is not set in configuration file '$CONFIG_FILE'."
        exit 1
    fi
done

# Determine final backup location: CLI > Config file's BACKUP_LOCATION > default 'remote'
# BACKUP_LOCATION from config is already sourced. CLI_BACKUP_LOCATION holds the -l, -r, -b option.
# Let's rename the CLI option variable to avoid confusion with the config's BACKUP_LOCATION.
FINAL_BACKUP_LOCATION="${BACKUP_LOCATION_CLI:-${BACKUP_LOCATION:-remote}}" # BACKUP_LOCATION_CLI from getopts, BACKUP_LOCATION from config
# This was slightly off. `getopts` directly sets `BACKUP_LOCATION`. So, if -l, -r, or -b is used, `BACKUP_LOCATION` is set.
# If not, it remains empty, then `BACKUP_LOCATION` from config is used. If that's also empty, it defaults to 'remote'.
# Corrected logic:
if [ -z "$BACKUP_LOCATION" ]; then # If -l, -r, -b were NOT used
    BACKUP_LOCATION="${BACKUP_LOCATION_CONFIG:-remote}" # Use config's or default to remote. (Assume BACKUP_LOCATION_CONFIG is the var name in .conf)
                                                       # For now, assuming the sourced config var is also named BACKUP_LOCATION
fi


# Check SSH settings if remote backup location is involved
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then # These vars must be set in the config file
            log "ERROR" "Required SSH variable '$var' for remote backup is not set in '$CONFIG_FILE'."
            exit 1
        fi
    done
fi

# --- Define backup directories and final filenames ---
# DIR is typically set by common.sh (current timestamp), or can be overridden by config
BACKUP_DIR_STAGING="${BACKUP_DIR_STAGING:-$SCRIPTPATH/backups}" # Main staging area for temp files
LOCAL_BACKUP_DIR_FINAL="${LOCAL_BACKUP_DIR_FINAL:-$SCRIPTPATH/local_backups}" # Final local storage path

DEST_TEMP="$BACKUP_DIR_STAGING/$DIR" # Temporary directory for this specific backup instance

FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}" # From config or default
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT_FILES:-tar.gz}}" # CLI > Config (COMPRESSION_FORMAT_FILES) > Default (tar.gz)
NICE_LEVEL="${NICE_LEVEL:-19}"
EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-wp-staging,*.log,cache,wpo-cache,backup*,*backups,node_modules}" # Added more common excludes
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
LAST_BACKUP_FILE_PATH="$SCRIPTPATH/logs/last_files_backup_path.txt" # Stores path of the last successful files backup's staging dir

FORMATTED_SUFFIX="" # Prepare suffix part for the filename
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi
FILES_FILENAME="${FILES_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}"

# Prepare EXCLUDE_ARGS for rsync from comma-separated string
EXCLUDE_ARGS=""
if [ -n "$EXCLUDE_PATTERNS" ]; then
    IFS=',' read -ra PATTERNS_ARRAY <<< "$EXCLUDE_PATTERNS"
    for pattern_item in "${PATTERNS_ARRAY[@]}"; do
        pattern_item_trimmed=$(echo "$pattern_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') # Trim whitespace
        if [ -n "$pattern_item_trimmed" ]; then
             EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern_item_trimmed'"
        fi
    done
fi

# --- Cleanup Function Trap ---
cleanup_files() {
    log "INFO" "Files backup process ended. Cleaning up temporary directory: $DEST_TEMP ..."
    if [ -d "$DEST_TEMP" ]; then
        rm -rf "$DEST_TEMP"
        log "INFO" "Temporary directory $DEST_TEMP removed."
    fi
}
trap cleanup_files EXIT INT TERM

# --- Main Backup Logic ---
if ! $QUIET; then
    echo -e "${CYAN}Starting files backup for '${wpHost:-$(basename "$wpPath")}'...${NC}"
    echo -e "${INFO}Backup Target Location: ${BOLD}$BACKUP_LOCATION${NC}"
    if [ "$INCREMENTAL" = true ]; then
        echo -e "${INFO}Incremental Backup: ${BOLD}Enabled${NC}"
    fi
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${INFO}Filename Suffix: ${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${INFO}Final Filename (approx): ${BOLD}${FILES_FILENAME}${NC}"
fi

log "INFO" "Starting files backup (Instance: $DIR, Target: $BACKUP_LOCATION, Incremental: $INCREMENTAL, Suffix: '$NAME_SUFFIX')"
update_status "STARTED" "Files backup process for ${wpHost:-$DIR} to $BACKUP_LOCATION"

# Validate SSH connection if remote backup is involved
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Files Backup SSH Check"
    log "INFO" "SSH connection to $destinationUser@$destinationIP:$destinationPort validated."
fi

# Create necessary directories if not in dry run mode
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating directories: Staging='$BACKUP_DIR_STAGING', InstanceTemp='$DEST_TEMP'."
    mkdir -pv "$BACKUP_DIR_STAGING"
    check_status $? "Create main backup staging directory '$BACKUP_DIR_STAGING'" "Files Backup"
    mkdir -pv "$DEST_TEMP"
    check_status $? "Create instance temporary directory '$DEST_TEMP'" "Files Backup"
    
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR_FINAL"
        check_status $? "Create final local backup directory '$LOCAL_BACKUP_DIR_FINAL'" "Files Backup"
    fi
else
    log "INFO" "[Dry Run] Skipping directory creation."
fi

# --- Perform Files Backup ---
FILES_SIZE_HR="N/A (Dry Run)"
if [ "$DRY_RUN" = false ]; then
    FILES_DUMP_DIR="$DEST_TEMP/Files_Content" # Subdirectory for rsync content
    mkdir -pv "$FILES_DUMP_DIR"
    check_status $? "Create content dump subdirectory '$FILES_DUMP_DIR'" "Files Backup"

    RSYNC_BASE_OPTS="-a --delete --info=progress2" # Archive, delete extraneous, show progress
    # Add --max-size if defined in config or common.sh, e.g. "${rsyncMaxSizeOpt}"
    # RSYNC_OPTS="$RSYNC_BASE_OPTS ${rsyncMaxSizeOpt}"
    RSYNC_OPTS="$RSYNC_BASE_OPTS --max-size=${maxFileSizeRsync:-100m}" # Example: max file size 100m

    # Handle incremental backup logic
    if [ "$INCREMENTAL" = true ]; then
        if [ -f "$LAST_BACKUP_FILE_PATH" ] && [ -s "$LAST_BACKUP_FILE_PATH" ]; then
            PREVIOUS_BACKUP_STAGING_DIR=$(cat "$LAST_BACKUP_FILE_PATH")
            # For --link-dest, the path should be to the *source* structure of the previous backup.
            # If $PREVIOUS_BACKUP_STAGING_DIR stored $DEST_TEMP of previous run, then it had Files_Content/
            if [ -d "$PREVIOUS_BACKUP_STAGING_DIR/Files_Content" ]; then
                log "INFO" "Performing incremental files backup using reference: $PREVIOUS_BACKUP_STAGING_DIR/Files_Content"
                if ! $QUIET; then echo -e "${CYAN}${BOLD}Performing incremental files backup...${NC}"; fi
                RSYNC_OPTS="$RSYNC_OPTS --link-dest=\"$PREVIOUS_BACKUP_STAGING_DIR/Files_Content\""
            else
                log "WARNING" "Previous backup's content directory '$PREVIOUS_BACKUP_STAGING_DIR/Files_Content' not found. Performing full files backup instead."
                INCREMENTAL="false" # Fallback to full
            fi
        else
            log "WARNING" "Last backup reference file '$LAST_BACKUP_FILE_PATH' not found or empty. Performing full files backup."
            INCREMENTAL="false" # Fallback to full
        fi
    fi
    
    if [ "$INCREMENTAL" = "false" ]; then # Log if doing full (either by choice or fallback)
        log "INFO" "Performing full files backup."
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Performing full files backup...${NC}"; fi
    fi

    # Using eval with rsync due to EXCLUDE_ARGS and RSYNC_OPTS potentially containing quoted arguments
    RSYNC_CMD="nice -n \"$NICE_LEVEL\" rsync $RSYNC_OPTS $EXCLUDE_ARGS \"$wpPath/\" \"$FILES_DUMP_DIR/\""
    log "DEBUG" "Executing rsync command: $RSYNC_CMD"
    eval "$RSYNC_CMD"
    check_status $? "Rsync WordPress files (Type: $([ "$INCREMENTAL" = true ] && echo "Incremental" || echo "Full"))" "Files Backup"

    # If backup was successful (full or incremental), save current staging path for next incremental
    echo "$DEST_TEMP" > "$LAST_BACKUP_FILE_PATH"
    log "INFO" "Current backup staging path '$DEST_TEMP' saved to '$LAST_BACKUP_FILE_PATH' for future incremental reference."

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing backed up files...${NC}"; fi
    compress "$FILES_DUMP_DIR" "$DEST_TEMP/$FILES_FILENAME" # compress function from common.sh
    check_status $? "Compress files dump '$FILES_DUMP_DIR' to '$DEST_TEMP/$FILES_FILENAME'" "Files Backup"

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up raw files dump directory...${NC}"; fi
    rm -rf "$FILES_DUMP_DIR" # Remove the uncompressed files directory
    check_status $? "Clean up raw files dump directory '$FILES_DUMP_DIR'" "Files Backup"

    if [ -f "$DEST_TEMP/$FILES_FILENAME" ]; then
        FILES_SIZE_BYTES=$(du -b "$DEST_TEMP/$FILES_FILENAME" | cut -f1)
        FILES_SIZE_HR=$(human_readable_size "$FILES_SIZE_BYTES")
        log "INFO" "Files backup created and compressed: $DEST_TEMP/$FILES_FILENAME (Size: $FILES_SIZE_HR)"
    else
        log "ERROR" "Compressed files backup '$DEST_TEMP/$FILES_FILENAME' not found. Aborting."
        FILES_SIZE_HR="Error"
        exit 1
    fi

    # --- Handle Backup Location ---
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Moving backup to final local storage: $LOCAL_BACKUP_DIR_FINAL/$FILES_FILENAME"
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Moving files backup to local storage: $LOCAL_BACKUP_DIR_FINAL ...${NC}"; fi
            mv -v "$DEST_TEMP/$FILES_FILENAME" "$LOCAL_BACKUP_DIR_FINAL/"
            check_status $? "Move files backup to final local directory" "Files Backup"
            ;;
        remote)
            log "INFO" "Uploading backup to remote server: $destinationUser@$destinationIP:$destinationFilesBackupPath"
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"; fi
            nice -n "$NICE_LEVEL" rsync -az --info=progress2 --remove-source-files \
                -e "ssh -p ${destinationPort:-22} -i \"${privateKeyPath}\"" \
                "$DEST_TEMP/$FILES_FILENAME" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath/"
            check_status $? "Upload files backup to remote server and remove source" "Files Backup"
            ;;
        both)
            log "INFO" "Copying backup to local storage and uploading to remote server."
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying files backup to local storage: $LOCAL_BACKUP_DIR_FINAL ...${NC}"; fi
            cp -v "$DEST_TEMP/$FILES_FILENAME" "$LOCAL_BACKUP_DIR_FINAL/"
            check_status $? "Copy files backup to final local directory" "Files Backup"

            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading files backup to remote server...${NC}"; fi
            nice -n "$NICE_LEVEL" rsync -az --info=progress2 \
                -e "ssh -p ${destinationPort:-22} -i \"${privateKeyPath}\"" \
                "$DEST_TEMP/$FILES_FILENAME" \
                "$destinationUser@$destinationIP:$destinationFilesBackupPath/"
            check_status $? "Upload files backup to remote server" "Files Backup"
            ;;
    esac
else
    log "INFO" "[Dry Run] Skipping actual files backup, compression, and transfer."
    if ! $QUIET; then echo -e "${YELLOW}[Dry Run] Would rsync, compress, and store files backup named (approx) '${FILES_FILENAME}'.${NC}"; fi
fi

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration "$DURATION")

log "INFO" "Files backup process for ${wpHost:-$DIR} completed. Target: $BACKUP_LOCATION. Duration: ${FORMATTED_DURATION}."
update_status "SUCCESS" "Files backup for ${wpHost:-$DIR} to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}."

if [ "${NOTIFY_ON_SUCCESS:-true}" = true ] && [ "$DRY_RUN" = false ]; then
    notify "SUCCESS" "Files backup for ${wpHost:-$(basename "$wpPath")} (Suffix: '$NAME_SUFFIX', Instance: $DIR, Incremental: $INCREMENTAL) completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}. File: $FILES_FILENAME, Size: $FILES_SIZE_HR." "Files Backup"
fi

if ! $QUIET; then
    echo -e "\n${GREEN}${BOLD}Files backup process completed successfully!${NC}"
    echo -e "${GREEN}Target Location(s): ${NC}${BOLD}${BACKUP_LOCATION}${NC}"
    if [ "$DRY_RUN" = false ]; then
        echo -e "${GREEN}Backup Type:        ${NC}${BOLD}$([ "$INCREMENTAL" = true ] && echo "Incremental" || echo "Full")${NC}"
    fi
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom Suffix Used: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time Taken:         ${NC}${BOLD}${FORMATTED_DURATION}${NC}"
    
    FINAL_FILES_PATH_DISPLAY="N/A"
    if [ "$DRY_RUN" = false ]; then
        case "$BACKUP_LOCATION" in
            "local") FINAL_FILES_PATH_DISPLAY="$LOCAL_BACKUP_DIR_FINAL/$FILES_FILENAME";;
            "remote") FINAL_FILES_PATH_DISPLAY="$destinationUser@$destinationIP:$destinationFilesBackupPath/$FILES_FILENAME";;
            "both") FINAL_FILES_PATH_DISPLAY="$LOCAL_BACKUP_DIR_FINAL/$FILES_FILENAME (and remote at $destinationUser@$destinationIP:$destinationFilesBackupPath/$FILES_FILENAME)";;
        esac
        echo -e "${GREEN}Backup File:        ${NC}${FINAL_FILES_PATH_DISPLAY} (${FILES_SIZE_HR})"
    else
        echo -e "${YELLOW}Dry Run - Filename would be (approx): ${NC}${FILES_FILENAME}"
    fi
fi

# The EXIT trap (cleanup_files) will handle removal of $DEST_TEMP
exit 0