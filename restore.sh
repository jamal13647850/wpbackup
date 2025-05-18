#!/bin/bash
# restore.sh - WordPress restore script
# Author: System Administrator
# Last updated: 2025-05-17

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/restore.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/restore_status.log}"

# Initialize default values
DRY_RUN=false
VERBOSE=false
RESTORE_TYPE="full"  # Default to full restore (both DB and files)
BACKUP_SOURCE=""
FORCE=false

# Parse command line options
while getopts "c:b:s:t:dfv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        b) BACKUP_FILE="$OPTARG";;
        s) BACKUP_SOURCE="$OPTARG";;
        t) RESTORE_TYPE="$OPTARG";;
        d) DRY_RUN=true;;
        f) FORCE=true;;
        v) VERBOSE=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-b <backup_file>] [-s <source>] [-t <type>] [-d] [-f] [-v]" >&2
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  -b: Specific backup file to restore (if not specified, latest will be used)"
            echo -e "  -s: Backup source (local, remote)"
            echo -e "  -t: Restore type (full, db, files)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -f: Force restore without confirmation"
            echo -e "  -v: Verbose output"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Restore"

# If no config file specified, prompt user to select one
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "restore"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
fi

# Process the configuration file (handles both encrypted and regular files)
process_config_file "$CONFIG_FILE" "Restore"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Set default values
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
RESTORE_DIR="${RESTORE_DIR:-$SCRIPTPATH/restore_tmp}"
BACKUP_SOURCE="${BACKUP_SOURCE:-${BACKUP_LOCATION:-local}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"

# Validate remote backup settings if needed
if [ "$BACKUP_SOURCE" = "remote" ]; then
    for var in destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in $CONFIG_FILE for remote restore!${NC}" >&2
            exit 1
        fi
    done
fi

# Function for cleanup operations specific to restore
cleanup_restore() {
    cleanup "Restore process" "Restore"
    rm -rf "$RESTORE_DIR"
}
trap cleanup_restore INT TERM

# Log start of restore process
log "INFO" "Starting restore process from $BACKUP_SOURCE (Type: $RESTORE_TYPE)"
update_status "STARTED" "Restore process from $BACKUP_SOURCE"

# Validate SSH connection if needed
if [ "$BACKUP_SOURCE" = "remote" ]; then
    validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath" "Restore"
    log "INFO" "SSH connection validated successfully"
fi

# Create temporary directory for restore
if [ "$DRY_RUN" = false ]; then
    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
    check_status $? "Creating restore directory" "Restore"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

# Function to find the latest backup file
find_latest_backup() {
    local prefix="$1"
    local source="$2"
    local path="$3"
    local latest=""
    
    if [ "$source" = "local" ]; then
        latest=$(ls -t "$path/$prefix"* 2>/dev/null | head -n 1)
    else
        latest=$(ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "ls -t $path/$prefix* 2>/dev/null | head -n 1")
    fi
    
    if [ -z "$latest" ]; then
        echo -e "${RED}${BOLD}Error: No $prefix backup found in $path!${NC}" >&2
        return 1
    fi
    
    echo "$latest"
    return 0
}

# Function to download or copy backup file
get_backup_file() {
    local source_path="$1"
    local dest_path="$2"
    local source_type="$3"
    
    if [ "$source_type" = "local" ]; then
        echo -e "${CYAN}${BOLD}Copying backup file from local storage...${NC}"
        cp -v "$source_path" "$dest_path"
    else
        echo -e "${CYAN}${BOLD}Downloading backup file from remote storage...${NC}"
        scp -P "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP:$source_path" "$dest_path"
    fi
    
    return $?
}

# Determine backup files to restore
DB_FILE_PREFIX="${DB_FILE_PREFIX:-DB}"
FILES_FILE_PREFIX="${FILES_FILE_PREFIX:-Files}"

if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
    if [ -n "$BACKUP_FILE" ] && [[ "$(basename "$BACKUP_FILE")" == "${DB_FILE_PREFIX}-"* ]]; then
        DB_BACKUP_FILE="$BACKUP_FILE"
    else
        if [ "$BACKUP_SOURCE" = "local" ]; then
            DB_BACKUP_FILE=$(find_latest_backup "${DB_FILE_PREFIX}-" "local" "$LOCAL_BACKUP_DIR")
        else
            DB_BACKUP_FILE=$(find_latest_backup "${DB_FILE_PREFIX}-" "remote" "$destinationDbBackupPath")
        fi
    fi
    
    if [ $? -ne 0 ] || [ -z "$DB_BACKUP_FILE" ]; then
        echo -e "${RED}${BOLD}Error: Failed to find database backup file!${NC}" >&2
        exit 1
    fi
    
    log "INFO" "Using database backup: $(basename "$DB_BACKUP_FILE")"
    echo -e "${GREEN}Using database backup: ${BOLD}$(basename "$DB_BACKUP_FILE")${NC}"
fi

if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
    if [ -n "$BACKUP_FILE" ] && [[ "$(basename "$BACKUP_FILE")" == "${FILES_FILE_PREFIX}-"* ]]; then
        FILES_BACKUP_FILE="$BACKUP_FILE"
    else
        if [ "$BACKUP_SOURCE" = "local" ]; then
            FILES_BACKUP_FILE=$(find_latest_backup "${FILES_FILE_PREFIX}-" "local" "$LOCAL_BACKUP_DIR")
        else
            FILES_BACKUP_FILE=$(find_latest_backup "${FILES_FILE_PREFIX}-" "remote" "$destinationFilesBackupPath")
        fi
    fi
    
    if [ $? -ne 0 ] || [ -z "$FILES_BACKUP_FILE" ]; then
        echo -e "${RED}${BOLD}Error: Failed to find files backup file!${NC}" >&2
        exit 1
    fi
    
    log "INFO" "Using files backup: $(basename "$FILES_BACKUP_FILE")"
    echo -e "${GREEN}Using files backup: ${BOLD}$(basename "$FILES_BACKUP_FILE")${NC}"
fi

# Confirm restore operation if not forced
if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
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
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Restore operation cancelled by user.${NC}"
        exit 0
    fi
fi

# Download or copy backup files
if [ "$DRY_RUN" = false ]; then
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
        get_backup_file "$DB_BACKUP_FILE" "$RESTORE_DIR/$(basename "$DB_BACKUP_FILE")" "$BACKUP_SOURCE"
        check_status $? "Getting database backup file" "Restore"
    fi
    
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
        get_backup_file "$FILES_BACKUP_FILE" "$RESTORE_DIR/$(basename "$FILES_BACKUP_FILE")" "$BACKUP_SOURCE"
        check_status $? "Getting files backup file" "Restore"
    fi
else
    log "INFO" "Dry run: Skipping backup file retrieval"
fi

# Extract backup files
if [ "$DRY_RUN" = false ]; then
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
        echo -e "${CYAN}${BOLD}Extracting database backup...${NC}"
        extract_backup "$RESTORE_DIR/$(basename "$DB_BACKUP_FILE")" "$RESTORE_DIR/DB"
        check_status $? "Extracting database backup" "Restore"
    fi
    
    if [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
        echo -e "${CYAN}${BOLD}Extracting files backup...${NC}"
        extract_backup "$RESTORE_DIR/$(basename "$FILES_BACKUP_FILE")" "$RESTORE_DIR/Files"
        check_status $? "Extracting files backup" "Restore"
    fi
else
    log "INFO" "Dry run: Skipping backup extraction"
fi

# Restore database
if [ "$DRY_RUN" = false ] && [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "db" ]; then
    echo -e "${CYAN}${BOLD}Restoring database...${NC}"
    
    # Find SQL file
    SQL_FILE=$(find "$RESTORE_DIR/DB" -name "*.sql" | head -n 1)
    if [ -z "$SQL_FILE" ]; then
        echo -e "${RED}${BOLD}Error: No SQL file found in database backup!${NC}" >&2
        exit 1
    fi
    
    # Import database
    nice -n "$NICE_LEVEL" wp db import "$SQL_FILE" --path="$wpPath"
    check_status $? "Database restore" "Restore"
    
    log "INFO" "Database restored successfully"
    echo -e "${GREEN}Database restored successfully!${NC}"
fi

# Restore files
if [ "$DRY_RUN" = false ] && [ "$RESTORE_TYPE" = "full" ] || [ "$RESTORE_TYPE" = "files" ]; then
    echo -e "${CYAN}${BOLD}Restoring files...${NC}"
    
    # Check if Files directory exists
    if [ ! -d "$RESTORE_DIR/Files" ]; then
        echo -e "${RED}${BOLD}Error: Files directory not found in backup!${NC}" >&2
        exit 1
    fi
    
    # Create backup of wp-config.php if it exists
    if [ -f "$wpPath/wp-config.php" ]; then
        cp -v "$wpPath/wp-config.php" "$RESTORE_DIR/wp-config.php.bak"
        check_status $? "Backing up wp-config.php" "Restore"
    fi
    
    # Sync files (excluding wp-config.php)
    rsync -a --progress --exclude="wp-config.php" "$RESTORE_DIR/Files/" "$wpPath/"
    check_status $? "Files restore" "Restore"
    
    # Restore wp-config.php from backup if it was backed up
    if [ -f "$RESTORE_DIR/wp-config.php.bak" ]; then
        cp -v "$RESTORE_DIR/wp-config.php.bak" "$wpPath/wp-config.php"
        check_status $? "Restoring wp-config.php" "Restore"
    fi
    
    log "INFO" "Files restored successfully"
    echo -e "${GREEN}Files restored successfully!${NC}"
fi

# Clean up temporary files
if [ "$DRY_RUN" = false ]; then
    echo -e "${CYAN}${BOLD}Cleaning up temporary files...${NC}"
    rm -rf "$RESTORE_DIR"
    check_status $? "Cleaning up temporary files" "Restore"
fi

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Restore process completed successfully in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Restore process completed in ${FORMATTED_DURATION}"

echo -e "${GREEN}${BOLD}Restore process completed successfully!${NC}"
echo -e "${GREEN}Restore source: ${NC}${BACKUP_SOURCE}"
echo -e "${GREEN}Restore type: ${NC}${RESTORE_TYPE}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
