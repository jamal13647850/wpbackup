#!/bin/bash
#
# Script: database.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Performs WordPress database backup with options for local/remote storage and custom naming.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/database.log" # Log file for this specific script
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/database_status.log}" # Status log for this script

# --- Default values for options ---
DRY_RUN=false
VERBOSE=false
QUIET=false               # Suppress non-essential output and interactive prompts
BACKUP_LOCATION="remote"  # Default backup location (remote, local, both)
NAME_SUFFIX=""            # Optional custom suffix for the backup filename

# Parse command line options
while getopts "c:f:dlrbqn:v" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";; # Override compression format (e.g., zip, tar.gz)
        d) DRY_RUN=true;;
        l) BACKUP_LOCATION="local";;
        r) BACKUP_LOCATION="remote";;
        b) BACKUP_LOCATION="both";;
        q) QUIET=true;;
        n) NAME_SUFFIX="$OPTARG";;
        v) VERBOSE=true;;
        \?) # Handle invalid options
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-q] [-n <suffix>] [-v]" >&2
            echo -e "  -c: Configuration file (can be .conf.gpg or .conf)" >&2
            echo -e "  -f: Override compression format (e.g., zip, tar.gz, tar)" >&2
            echo -e "  -d: Dry run (simulate changes, no actual backup)" >&2
            echo -e "  -l: Store backup locally only" >&2
            echo -e "  -r: Store backup remotely only" >&2
            echo -e "  -b: Store backup both locally and remotely" >&2
            echo -e "  -q: Quiet mode (minimal output, suppresses interactive prompts)" >&2
            echo -e "  -n: Custom suffix for backup filename (e.g., 'db-schema-change')" >&2
            echo -e "  -v: Verbose output" >&2
            exit 1
            ;;
    esac
done

# --- Interactive prompt for NAME_SUFFIX if not provided via -n and not in QUIET mode ---
if [ -z "$NAME_SUFFIX" ] && [ "${QUIET}" = false ]; then
    echo -e "${YELLOW}Do you want to add a custom suffix to the database backup filename? (y/N):${NC}"
    read -r -p "> " confirm_suffix
    if [[ "$confirm_suffix" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Enter custom suffix (e.g., 'critical-update-prep'):${NC}"
        read -r -p "> " interactive_suffix
        if [ -n "$interactive_suffix" ]; then
            NAME_SUFFIX=$(sanitize_filename_suffix "$interactive_suffix") # Sanitize input using common.sh function
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

# Initialize log (after QUIET and NAME_SUFFIX are potentially set)
init_log "WordPress Database Backup"

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "database backup"; then # Interactive selection
        log "ERROR" "Configuration file selection failed or was cancelled."
        exit 1
    fi
# Ensure specified config file exists if provided directly
elif [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR" "Configuration file '$CONFIG_FILE' not found."
    exit 1
fi
process_config_file "$CONFIG_FILE" "Database Backup" # Load and source the config

# Validate required configuration variables from config file
for var in wpPath; do # Essential for wp-cli
    if [ -z "${!var}" ]; then
        log "ERROR" "Required variable '$var' is not set in configuration file '$CONFIG_FILE'."
        exit 1
    fi
done

# Check SSH settings if remote backup location is selected
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
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

DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}" # From config or default
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-tar.gz}}" # CLI > Config > Default (tar.gz for DB)
NICE_LEVEL="${NICE_LEVEL:-19}"       # CPU niceness for operations
LOG_LEVEL="${VERBOSE:+verbose}"      # Set by common.sh based on -v
LOG_LEVEL="${LOG_LEVEL:-normal}"     # Default if not verbose

FORMATTED_SUFFIX="" # Prepare suffix part for the filename
if [ -n "$NAME_SUFFIX" ]; then
    FORMATTED_SUFFIX="-${NAME_SUFFIX}"
fi
DB_FILENAME="${DB_FILE_PREFIX}-${DIR}${FORMATTED_SUFFIX}.${COMPRESSION_FORMAT}"

# --- Cleanup Function Trap ---
# Ensures temporary directory ($DEST_TEMP) is removed on script exit or interruption
cleanup_database() {
    log "INFO" "Database backup process ended. Cleaning up temporary directory: $DEST_TEMP ..."
    if [ -d "$DEST_TEMP" ]; then
        rm -rf "$DEST_TEMP"
        log "INFO" "Temporary directory $DEST_TEMP removed."
    fi
    # update_status is handled by the calling script or final status update
}
trap cleanup_database EXIT INT TERM # Use EXIT trap for robust cleanup

# --- Main Backup Logic ---
if ! $QUIET; then
    echo -e "${CYAN}Starting database backup for '${wpHost:-$(basename "$wpPath")}'...${NC}"
    echo -e "${INFO}Backup Target Location: ${BOLD}$BACKUP_LOCATION${NC}"
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${INFO}Filename Suffix: ${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${INFO}Final Filename (approx): ${BOLD}${DB_FILENAME}${NC}"
fi

log "INFO" "Starting database backup (Instance: $DIR, Target: $BACKUP_LOCATION, Suffix: '$NAME_SUFFIX')"
update_status "STARTED" "Database backup process for ${wpHost:-$DIR} to $BACKUP_LOCATION"

# Validate SSH connection if remote backup is involved
if [ "$BACKUP_LOCATION" = "remote" ] || [ "$BACKUP_LOCATION" = "both" ]; then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Database Backup SSH Check"
    # validate_ssh from common.sh handles check_status and logging internally
    log "INFO" "SSH connection to $destinationUser@$destinationIP:$destinationPort validated successfully."
fi

# Create necessary directories if not in dry run mode
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating directories: Staging='$BACKUP_DIR_STAGING', InstanceTemp='$DEST_TEMP'."
    mkdir -pv "$BACKUP_DIR_STAGING" # Main parent staging directory
    check_status $? "Create main backup staging directory '$BACKUP_DIR_STAGING'" "Database Backup"
    mkdir -pv "$DEST_TEMP"          # Specific temporary directory for this backup instance
    check_status $? "Create instance temporary directory '$DEST_TEMP'" "Database Backup"
    
    if [ "$BACKUP_LOCATION" = "local" ] || [ "$BACKUP_LOCATION" = "both" ]; then
        mkdir -pv "$LOCAL_BACKUP_DIR_FINAL" # Final local storage directory
        check_status $? "Create final local backup directory '$LOCAL_BACKUP_DIR_FINAL'" "Database Backup"
    fi
else
    log "INFO" "[Dry Run] Skipping directory creation."
fi

# --- Perform Database Backup ---
DB_SIZE_HR="N/A (Dry Run)"
if [ "$DRY_RUN" = false ]; then
    DB_DUMP_DIR="$DEST_TEMP/DB_DUMP" # Subdirectory within instance temp for the raw SQL dump
    mkdir -pv "$DB_DUMP_DIR"
    check_status $? "Create raw DB dump subdirectory '$DB_DUMP_DIR'" "Database Backup"
    
    SQL_FILE_NAME="database-${DIR}.sql" # Name of the raw SQL file
    
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Exporting database from WordPress path: $wpPath...${NC}"; fi
    # Using wp_cli wrapper from common.sh which handles nice level
    wp_cli db export "$DB_DUMP_DIR/$SQL_FILE_NAME" --add-drop-table --path="$wpPath"
    check_status $? "Export database using wp-cli to '$DB_DUMP_DIR/$SQL_FILE_NAME'" "Database Backup"
    
    if [ ! -s "$DB_DUMP_DIR/$SQL_FILE_NAME" ]; then # Check if SQL file is not empty
        log "ERROR" "Database export file '$DB_DUMP_DIR/$SQL_FILE_NAME' is empty or not created. Aborting."
        exit 1
    fi

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Compressing database dump...${NC}"; fi
    # Compress the DUMP subdirectory into the $DEST_TEMP directory with the final $DB_FILENAME
    compress "$DB_DUMP_DIR" "$DEST_TEMP/$DB_FILENAME" # compress function from common.sh
    check_status $? "Compress database dump '$DB_DUMP_DIR' to '$DEST_TEMP/$DB_FILENAME'" "Database Backup"

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Cleaning up raw database dump directory...${NC}"; fi
    rm -rf "$DB_DUMP_DIR" # Remove the uncompressed dump directory
    check_status $? "Clean up raw DB dump directory '$DB_DUMP_DIR'" "Database Backup"

    if [ -f "$DEST_TEMP/$DB_FILENAME" ]; then
        DB_SIZE_BYTES=$(du -b "$DEST_TEMP/$DB_FILENAME" | cut -f1)
        DB_SIZE_HR=$(human_readable_size "$DB_SIZE_BYTES")
        log "INFO" "Database backup created and compressed: $DEST_TEMP/$DB_FILENAME (Size: $DB_SIZE_HR)"
    else
        log "ERROR" "Compressed database backup file '$DEST_TEMP/$DB_FILENAME' not found. Aborting."
        DB_SIZE_HR="Error"
        exit 1
    fi

    # --- Handle Backup Location ---
    case $BACKUP_LOCATION in
        local)
            log "INFO" "Moving backup to final local storage: $LOCAL_BACKUP_DIR_FINAL/$DB_FILENAME"
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Moving database backup to local storage: $LOCAL_BACKUP_DIR_FINAL ...${NC}"; fi
            mv -v "$DEST_TEMP/$DB_FILENAME" "$LOCAL_BACKUP_DIR_FINAL/"
            check_status $? "Move database backup to final local directory" "Database Backup"
            # DEST_TEMP will be cleaned by the EXIT trap
            ;;
        remote)
            log "INFO" "Uploading backup to remote server: $destinationUser@$destinationIP:$destinationDbBackupPath"
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"; fi
            # Using rsync for remote transfer; common.sh does not have a generic 'transfer' function
            nice -n "$NICE_LEVEL" rsync -az --info=progress2 --remove-source-files \
                -e "ssh -p ${destinationPort:-22} -i \"${privateKeyPath}\"" \
                "$DEST_TEMP/$DB_FILENAME" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath/"
            check_status $? "Upload database backup to remote server and remove source" "Database Backup"
            # --remove-source-files in rsync will delete $DEST_TEMP/$DB_FILENAME after successful transfer.
            # The $DEST_TEMP directory itself will be cleaned by the EXIT trap.
            ;;
        both)
            log "INFO" "Copying backup to local storage and uploading to remote server."
            if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying database backup to local storage: $LOCAL_BACKUP_DIR_FINAL ...${NC}"; fi
            cp -v "$DEST_TEMP/$DB_FILENAME" "$LOCAL_BACKUP_DIR_FINAL/"
            check_status $? "Copy database backup to final local directory" "Database Backup"

            if ! $QUIET; then echo -e "${CYAN}${BOLD}Uploading database backup to remote server...${NC}"; fi
            nice -n "$NICE_LEVEL" rsync -az --info=progress2 \
                -e "ssh -p ${destinationPort:-22} -i \"${privateKeyPath}\"" \
                "$DEST_TEMP/$DB_FILENAME" \
                "$destinationUser@$destinationIP:$destinationDbBackupPath/"
            check_status $? "Upload database backup to remote server" "Database Backup"
            # $DEST_TEMP/$DB_FILENAME remains for now, $DEST_TEMP dir cleaned by EXIT trap.
            ;;
    esac
else
    log "INFO" "[Dry Run] Skipping actual database backup, compression, and transfer."
    if ! $QUIET; then echo -e "${YELLOW}[Dry Run] Would export, compress, and store database backup named (approx) '${DB_FILENAME}'.${NC}"; fi
fi

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME)) # START_TIME from common.sh
FORMATTED_DURATION=$(format_duration "$DURATION") # format_duration from common.sh

log "INFO" "Database backup process for ${wpHost:-$DIR} completed. Target: $BACKUP_LOCATION. Duration: ${FORMATTED_DURATION}."
update_status "SUCCESS" "Database backup for ${wpHost:-$DIR} to $BACKUP_LOCATION completed in ${FORMATTED_DURATION}."
# Send notification if configured (NOTIFY_ON_SUCCESS should be from common.sh or config)
if [ "${NOTIFY_ON_SUCCESS:-true}" = true ] && [ "$DRY_RUN" = false ]; then
    notify "SUCCESS" "Database backup for ${wpHost:-$(basename "$wpPath")} (Suffix: '$NAME_SUFFIX', Instance: $DIR) completed to $BACKUP_LOCATION in ${FORMATTED_DURATION}. File: $DB_FILENAME, Size: $DB_SIZE_HR." "Database Backup"
fi

if ! $QUIET; then
    echo -e "\n${GREEN}${BOLD}Database backup process completed successfully!${NC}"
    echo -e "${GREEN}Target Location(s): ${NC}${BOLD}${BACKUP_LOCATION}${NC}"
    if [ -n "$FORMATTED_SUFFIX" ]; then
        echo -e "${GREEN}Custom Suffix Used: ${NC}${BOLD}${NAME_SUFFIX}${NC}"
    fi
    echo -e "${GREEN}Time Taken:         ${NC}${BOLD}${FORMATTED_DURATION}${NC}"
    
    FINAL_DB_PATH_DISPLAY="N/A"
    if [ "$DRY_RUN" = false ]; then
        case "$BACKUP_LOCATION" in
            "local") FINAL_DB_PATH_DISPLAY="$LOCAL_BACKUP_DIR_FINAL/$DB_FILENAME";;
            "remote") FINAL_DB_PATH_DISPLAY="$destinationUser@$destinationIP:$destinationDbBackupPath/$DB_FILENAME";;
            "both") FINAL_DB_PATH_DISPLAY="$LOCAL_BACKUP_DIR_FINAL/$DB_FILENAME (and remote at $destinationUser@$destinationIP:$destinationDbBackupPath/$DB_FILENAME)";;
        esac
        echo -e "${GREEN}Backup File:        ${NC}${FINAL_DB_PATH_DISPLAY} (${DB_SIZE_HR})"
    else
        echo -e "${YELLOW}Dry Run - Filename would be (approx): ${NC}${DB_FILENAME}"
    fi
fi

# The EXIT trap (cleanup_database) will handle removal of $DEST_TEMP
exit 0