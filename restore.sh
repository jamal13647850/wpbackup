#!/bin/bash
#
# Script: restore.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Restores WordPress from backup (database and/or files).

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/restore.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/restore_status.log}"

# --- Default values for options ---
DRY_RUN=false
VERBOSE=false
RESTORE_TYPE="full" # Default restore type
BACKUP_SOURCE=""    # Will be determined by config or CLI
BACKUP_FILE=""      # Specific backup file to restore (optional)
FORCE=false         # Force restore without confirmation
QUIET=false         # Suppress non-essential output

# Parse command line options
while getopts "c:b:s:t:dfqv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        b) BACKUP_FILE="$OPTARG";;
        s) BACKUP_SOURCE="$OPTARG";;
        t) RESTORE_TYPE="$OPTARG";;
        d) DRY_RUN=true;;
        f) FORCE=true;;
        q) QUIET=true;;
        v) VERBOSE=true;;
        \?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-b <backup_file>] [-s <source>] [-t <type>] [-d] [-f] [-q] [-v]" >&2
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)" >&2
            echo -e "  -b: Specific backup file to restore (if not specified, latest will be used)" >&2
            echo -e "  -s: Backup source (local, remote)" >&2
            echo -e "  -t: Restore type (full, db, files)" >&2
            echo -e "  -d: Dry run (no actual changes)" >&2
            echo -e "  -f: Force restore without confirmation" >&2
            echo -e "  -q: Quiet mode (minimal non-essential output)" >&2
            echo -e "  -v: Verbose output" >&2
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Restore"

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ];
then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "restore";
    then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
fi
# Process config file. This will source variables into the current shell.
process_config_file "$CONFIG_FILE" "Restore"

# Validate required configuration variables
for var in wpPath;
do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable '$var' is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Define backup directories and parameters from sourced config or defaults
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
RESTORE_DIR="${RESTORE_DIR:-$SCRIPTPATH/restore_tmp}"
# BACKUP_LOCATION is a config var, BACKUP_SOURCE can be overridden by CLI -s
BACKUP_SOURCE="${BACKUP_SOURCE:-${BACKUP_LOCATION:-local}}" # Default to local if nothing else is set
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"

# SSH Variables Check for remote source
if [ "$BACKUP_SOURCE" = "remote" ];
then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath;
    do
        if [ -z "${!var}" ];
        then
            echo -e "${RED}${BOLD}Error: Required SSH variable '$var' is not set in $CONFIG_FILE for remote restore!${NC}" >&2
            exit 1
        fi
    done
fi

# Cleanup function trap
cleanup_restore() {
    cleanup "Restore process" "Restore"
    if [ -d "$RESTORE_DIR" ]; then
        rm -rf "$RESTORE_DIR"
    fi
    # Unset environment variables potentially set by manage_backups.sh
    unset MGMT_DB_BKP_PATH
    unset MGMT_FILES_BKP_PATH
}
trap cleanup_restore EXIT INT TERM # Added EXIT trap as well

if ! $QUIET; then echo -e "${CYAN}Starting WordPress Restore Process...${NC}"; fi
log "INFO" "Starting restore process from $BACKUP_SOURCE (Type: $RESTORE_TYPE)"
update_status "STARTED" "Restore process from $BACKUP_SOURCE"

# Validate SSH if source is remote
if [ "$BACKUP_SOURCE" = "remote" ];
then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Restore"
    if [ $? -ne 0 ]; then exit 1; fi # Exit if validation fails
    log "INFO" "SSH connection validated successfully"
fi

# Create/Clean restore directory
if [ "$DRY_RUN" = false ];
then
    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
    check_status $? "Creating restore directory $RESTORE_DIR" "Restore"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

# Function to find the latest backup file
find_latest_backup() {
    local prefix="$1"      # Backup file prefix (e.g., DB-, Files-)
    local source_loc="$2"  # Source location ('local' or 'remote')
    local search_path="$3" # Path to search for backups
    local latest=""

    if [ "$source_loc" = "local" ];
    then
        latest=$(ls -t "$search_path/$prefix"* 2>/dev/null | head -n 1)
    else # remote
        latest=$(ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "ls -t $search_path/$prefix* 2>/dev/null | head -n 1")
    fi

    if [ -z "$latest" ];
    then
        echo -e "${RED}${BOLD}Error: No '$prefix' backup found in '$search_path' on source '$source_loc'!${NC}" >&2
        return 1
    fi

    echo "$latest"
    return 0
}

# Function to get (copy/scp) the backup file
get_backup_file() {
    local source_path="$1"    # Full path on source
    local dest_path="$2"      # Full path to destination (in RESTORE_DIR)
    local source_type_loc="$3" # 'local' or 'remote'

    if [ "$source_type_loc" = "local" ];
    then
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying backup file from local storage...${NC}"; fi
        cp -v "$source_path" "$dest_path"
    else # remote
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Downloading backup file from remote storage...${NC}"; fi
        scp -P "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP:$source_path" "$dest_path"
    fi

    return $?
}

# Determine backup files to use
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"

# Check environment variables for specific paths (used when called by manage_backups.sh for staged full restore)
OVERRIDE_DB_PATH="${MGMT_DB_BKP_PATH:-}"
OVERRIDE_FILES_PATH="${MGMT_FILES_BKP_PATH:-}"

DB_BACKUP_FILE=""
FILES_BACKUP_FILE=""

# Determine Database Backup File
if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
    if [ -n "$OVERRIDE_DB_PATH" ] && [ "$BACKUP_SOURCE" = "local" ] && [ "$RESTORE_TYPE" = "full" ]; then
        DB_BACKUP_FILE="$OVERRIDE_DB_PATH"
        log "INFO" "Using specific DB backup path from MGMT_DB_BKP_PATH (via manage_backups.sh): $(basename "$DB_BACKUP_FILE")"
    elif [ -n "$BACKUP_FILE" ] && [[ "$(basename "$BACKUP_FILE")" == "${DB_FILE_PREFIX}-"* ]]; then
        DB_BACKUP_FILE="$BACKUP_FILE"
    else
        if [ "$BACKUP_SOURCE" = "local" ]; then
            DB_BACKUP_FILE=$(find_latest_backup "${DB_FILE_PREFIX}-" "local" "$LOCAL_BACKUP_DIR")
        else # remote
            DB_BACKUP_FILE=$(find_latest_backup "${DB_FILE_PREFIX}-" "remote" "$destinationDbBackupPath")
        fi
    fi

    if [ $? -ne 0 ] || [ -z "$DB_BACKUP_FILE" ]; then
        echo -e "${RED}${BOLD}Error: Failed to find/determine database backup file!${NC}" >&2
        exit 1
    fi
    if ! $QUIET || [ -n "$OVERRIDE_DB_PATH" ]; then # Always show if overridden
        echo -e "${GREEN}Using database backup: ${BOLD}$(basename "$DB_BACKUP_FILE")${NC}";
    fi
    log "INFO" "Using database backup: $(basename "$DB_BACKUP_FILE")"
fi

# Determine Files Backup File
if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
    if [ -n "$OVERRIDE_FILES_PATH" ] && [ "$BACKUP_SOURCE" = "local" ] && [ "$RESTORE_TYPE" = "full" ]; then
        FILES_BACKUP_FILE="$OVERRIDE_FILES_PATH"
        log "INFO" "Using specific Files backup path from MGMT_FILES_BKP_PATH (via manage_backups.sh): $(basename "$FILES_BACKUP_FILE")"
    elif [ -n "$BACKUP_FILE" ] && [[ "$(basename "$BACKUP_FILE")" == "${FILES_FILE_PREFIX}-"* ]]; then
        FILES_BACKUP_FILE="$BACKUP_FILE"
    else
        if [ "$BACKUP_SOURCE" = "local" ]; then
            FILES_BACKUP_FILE=$(find_latest_backup "${FILES_FILE_PREFIX}-" "local" "$LOCAL_BACKUP_DIR")
        else # remote
            FILES_BACKUP_FILE=$(find_latest_backup "${FILES_FILE_PREFIX}-" "remote" "$destinationFilesBackupPath")
        fi
    fi

    if [ $? -ne 0 ] || [ -z "$FILES_BACKUP_FILE" ]; then
        echo -e "${RED}${BOLD}Error: Failed to find/determine files backup file!${NC}" >&2
        exit 1
    fi
    if ! $QUIET || [ -n "$OVERRIDE_FILES_PATH" ]; then # Always show if overridden
        echo -e "${GREEN}Using files backup: ${BOLD}$(basename "$FILES_BACKUP_FILE")${NC}";
    fi
    log "INFO" "Using files backup: $(basename "$FILES_BACKUP_FILE")"
fi

# Confirm restore operation if not forced and not dry run
if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ];
then
    echo -e "${YELLOW}${BOLD}Warning:${NC} This will overwrite your current WordPress installation!"
    echo -e "WordPress path: ${BOLD}$wpPath${NC}"
    echo -e "Restore type: ${BOLD}$RESTORE_TYPE${NC}"
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
        echo -e "Database backup: ${BOLD}$(basename "$DB_BACKUP_FILE")${NC}"
    fi
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
        echo -e "Files backup: ${BOLD}$(basename "$FILES_BACKUP_FILE")${NC}"
    fi
    echo ""
    read -r -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Restore operation cancelled by user.${NC}"
        exit 0
    fi
fi

# Get and Extract backups
if [ "$DRY_RUN" = false ];
then
    # Get DB backup
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ];
    then
        get_backup_file "$DB_BACKUP_FILE" "$RESTORE_DIR/$(basename "$DB_BACKUP_FILE")" "$BACKUP_SOURCE"
        check_status $? "Getting database backup file $(basename "$DB_BACKUP_FILE")" "Restore"
    fi

    # Get Files backup
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ];
    then
        get_backup_file "$FILES_BACKUP_FILE" "$RESTORE_DIR/$(basename "$FILES_BACKUP_FILE")" "$BACKUP_SOURCE"
        check_status $? "Getting files backup file $(basename "$FILES_BACKUP_FILE")" "Restore"
    fi
else
    log "INFO" "Dry run: Skipping backup file retrieval"
fi

if [ "$DRY_RUN" = false ];
then
    # Extract DB backup
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ];
    then
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Extracting database backup...${NC}"; fi
        extract_backup "$RESTORE_DIR/$(basename "$DB_BACKUP_FILE")" "$RESTORE_DIR/DB"
        check_status $? "Extracting database backup" "Restore"
    fi

    # Extract Files backup
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ];
    then
        if ! $QUIET; then echo -e "${CYAN}${BOLD}Extracting files backup...${NC}"; fi
        extract_backup "$RESTORE_DIR/$(basename "$FILES_BACKUP_FILE")" "$RESTORE_DIR/Files"
        check_status $? "Extracting files backup" "Restore"
    fi
else
    log "INFO" "Dry run: Skipping backup extraction"
fi

# Restore Database
if [ "$DRY_RUN" = false ] && { [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; }; then
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Restoring database...${NC}"; fi

    SQL_FILE=$(find "$RESTORE_DIR/DB" -maxdepth 1 -name "*.sql" 2>/dev/null | head -n 1) # Ensure it's in the root of DB extract dir
    if [ -z "$SQL_FILE" ];
    then
        echo -e "${RED}${BOLD}Error: No SQL file found in extracted database backup! Searched in '$RESTORE_DIR/DB'${NC}" >&2
        exit 1
    fi

    if ! $QUIET; then echo -e "${CYAN}Importing SQL file: $SQL_FILE ${NC}"; fi
    wp_cli db import "$SQL_FILE" --path="$wpPath"
    check_status $? "Database restore from $SQL_FILE" "Restore"

    log "INFO" "Database restored successfully from $(basename "$SQL_FILE")"
    if ! $QUIET; then echo -e "${GREEN}Database restored successfully!${NC}"; fi
fi

# Restore Files
if [ "$DRY_RUN" = false ] && { [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; }; then
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Restoring files...${NC}"; fi

    local extracted_files_content_path="$RESTORE_DIR/Files"
    # Check if $RESTORE_DIR/Files itself contains wp-content or wp-config.php. If not, and there's one subdir, use that.
    if ! ls "$extracted_files_content_path/"{wp-content,wp-config.php,wp-admin,wp-includes} >/dev/null 2>&1 ; then
        local subdirs_count
        subdirs_count=$(find "$extracted_files_content_path" -maxdepth 1 -mindepth 1 -type d | wc -l)
        if [ "$subdirs_count" -eq 1 ]; then
            local single_subdir
            single_subdir=$(find "$extracted_files_content_path" -maxdepth 1 -mindepth 1 -type d)
            if [ -d "$single_subdir" ]; then
                log "INFO" "Content appears to be in a subdirectory: $single_subdir. Using it as source for rsync."
                extracted_files_content_path="$single_subdir"
            fi
        fi
    fi
    
    if [ ! -d "$extracted_files_content_path" ]; then
        echo -e "${RED}${BOLD}Error: Files content directory '$extracted_files_content_path' not found in backup!${NC}" >&2
        exit 1
    fi

    # Backup current wp-config.php if it exists
    if [ -f "$wpPath/wp-config.php" ];
    then
        cp -v "$wpPath/wp-config.php" "$RESTORE_DIR/wp-config.php.bak"
        check_status $? "Backing up current wp-config.php" "Restore"
    fi

    # Rsync files, excluding wp-config.php from the backup archive itself
    # Ensure source path ends with a slash for rsync to copy contents
    if ! $QUIET; then echo -e "${CYAN}Rsyncing files from $extracted_files_content_path/ to $wpPath/${NC}"; fi
    rsync -av --progress --exclude="wp-config.php" "$extracted_files_content_path/" "$wpPath/"
    check_status $? "Files restore using rsync" "Restore"

    # Restore the original wp-config.php
    if [ -f "$RESTORE_DIR/wp-config.php.bak" ];
    then
        cp -v "$RESTORE_DIR/wp-config.php.bak" "$wpPath/wp-config.php"
        check_status $? "Restoring original wp-config.php" "Restore"
    fi

    log "INFO" "Files restored successfully"
    if ! $QUIET; then echo -e "${GREEN}Files restored successfully!${NC}"; fi
fi

# Final cleanup is handled by the trap calling cleanup_restore

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME)) # START_TIME should be defined in common.sh or at the beginning
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Restore process completed successfully in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Restore process completed in ${FORMATTED_DURATION}"

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Restore process completed successfully!${NC}"
    echo -e "${GREEN}Restore source: ${NC}${BOLD}${BACKUP_SOURCE}${NC}"
    echo -e "${GREEN}Restore type: ${NC}${BOLD}${RESTORE_TYPE}${NC}"
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}"
fi

# cleanup_restore will be called automatically on exit due to the trap.
exit 0