#!/bin/bash
. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/restore.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/restore_status.log}"

# Initialize variables with defaults
DRY_RUN=false
VERBOSE=false
RESTORE_DB=true
RESTORE_FILES=true
BACKUP_SOURCE=""

# Parse command line options
while getopts "c:b:dfvh" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        b) BACKUP_SOURCE="$OPTARG";;
        d) DRY_RUN=true;;
        f) RESTORE_FILES=true; RESTORE_DB=false;;
        v) VERBOSE=true; LOG_LEVEL="verbose";;
        h) 
            echo -e "${BLUE}${BOLD}WordPress Backup Restore Script${NC}"
            echo -e "${CYAN}Usage:${NC} $0 [options]"
            echo -e "${CYAN}Options:${NC}"
            echo -e "  -c <config_file>     Configuration file"
            echo -e "  -b <backup_source>   Backup file or directory to restore from"
            echo -e "  -d                   Dry run (no actual changes)"
            echo -e "  -f                   Restore files only (skip database)"
            echo -e "  -v                   Verbose output"
            echo -e "  -h                   Show this help"
            exit 0
            ;;
        ?) 
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> -b <backup_source> [-d] [-f] [-v]" >&2
            exit 1
            ;;
    esac
done

# If config file not specified, prompt for selection
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "restore"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$CONFIG_FILE")${NC}"
fi

# Source the config file directly
. "$CONFIG_FILE"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# If no backup source is specified, prompt for selection
if [ -z "$BACKUP_SOURCE" ]; then
    echo -e "${YELLOW}${BOLD}No backup source specified.${NC}"
    
    # Check if there are local backups
    LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
    if [ -d "$LOCAL_BACKUP_DIR" ]; then
        echo "Available local backups:"
        
        # List database backups
        DB_BACKUPS=()
        i=0
        while IFS= read -r file; do
            DB_BACKUPS+=("$file")
            echo "[$i] DB: $(basename "$file")"
            ((i++))
        done < <(find "$LOCAL_BACKUP_DIR" -type f -name "DB-*" | sort -r)
        
        # List file backups
        FILES_BACKUPS=()
        while IFS= read -r file; do
            FILES_BACKUPS+=("$file")
            echo "[$i] Files: $(basename "$file")"
            ((i++))
        done < <(find "$LOCAL_BACKUP_DIR" -type f -name "Files-*" | sort -r)
        
        # Check if any backups were found
        if [ ${#DB_BACKUPS[@]} -eq 0 ] && [ ${#FILES_BACKUPS[@]} -eq 0 ]; then
            echo -e "${RED}${BOLD}Error: No backups found in $LOCAL_BACKUP_DIR!${NC}" >&2
            exit 1
        fi
        
        # Prompt user to select backups
        if [ ${#DB_BACKUPS[@]} -gt 0 ] && [ "$RESTORE_DB" = true ]; then
            echo "Select a database backup by number (or leave empty to skip):"
            read -p "> " db_selection
            
            if [ -n "$db_selection" ]; then
                # Validate selection
                if ! [[ "$db_selection" =~ ^[0-9]+$ ]] || [ "$db_selection" -ge ${#DB_BACKUPS[@]} ]; then
                    echo -e "${RED}${BOLD}Error: Invalid database backup selection!${NC}" >&2
                    exit 1
                fi
                
                DB_BACKUP="${DB_BACKUPS[$db_selection]}"
                echo -e "${GREEN}Selected DB backup: $(basename "$DB_BACKUP")${NC}"
            else
                RESTORE_DB=false
            fi
        else
            RESTORE_DB=false
        fi
        
        if [ ${#FILES_BACKUPS[@]} -gt 0 ] && [ "$RESTORE_FILES" = true ]; then
            echo "Select a files backup by number (or leave empty to skip):"
            read -p "> " files_selection
            
            if [ -n "$files_selection" ]; then
                # Validate selection
                max_index=$((${#DB_BACKUPS[@]} + ${#FILES_BACKUPS[@]} - 1))
                if ! [[ "$files_selection" =~ ^[0-9]+$ ]] || [ "$files_selection" -gt $max_index ]; then
                    echo -e "${RED}${BOLD}Error: Invalid files backup selection!${NC}" >&2
                    exit 1
                fi
                
                # Adjust index for files backups
                files_index=$((files_selection - ${#DB_BACKUPS[@]}))
                if [ $files_index -lt 0 ]; then
                    echo -e "${RED}${BOLD}Error: Invalid files backup selection!${NC}" >&2
                    exit 1
                fi
                
                FILES_BACKUP="${FILES_BACKUPS[$files_index]}"
                echo -e "${GREEN}Selected files backup: $(basename "$FILES_BACKUP")${NC}"
            else
                RESTORE_FILES=false
            fi
        else
            RESTORE_FILES=false
        fi
    else
        echo -e "${RED}${BOLD}Error: Local backup directory $LOCAL_BACKUP_DIR not found!${NC}" >&2
        exit 1
    fi
else
    # Check if backup source exists
    if [ ! -f "$BACKUP_SOURCE" ] && [ ! -d "$BACKUP_SOURCE" ]; then
        echo -e "${RED}${BOLD}Error: Backup source $BACKUP_SOURCE not found!${NC}" >&2
        exit 1
    fi
    
    # If backup source is a directory, look for DB and Files backups
    if [ -d "$BACKUP_SOURCE" ]; then
        # Find the most recent DB backup
        DB_BACKUP=$(find "$BACKUP_SOURCE" -type f -name "DB-*" | sort -r | head -n 1)
        
        # Find the most recent Files backup
        FILES_BACKUP=$(find "$BACKUP_SOURCE" -type f -name "Files-*" | sort -r | head -n 1)
    else
        # If backup source is a file, determine if it's a DB or Files backup
        if [[ "$BACKUP_SOURCE" == *"DB-"* ]]; then
            DB_BACKUP="$BACKUP_SOURCE"
            RESTORE_FILES=false
        elif [[ "$BACKUP_SOURCE" == *"Files-"* ]]; then
            FILES_BACKUP="$BACKUP_SOURCE"
            RESTORE_DB=false
        else
            echo -e "${RED}${BOLD}Error: Cannot determine backup type for $BACKUP_SOURCE!${NC}" >&2
            exit 1
        fi
    fi
fi

# Cleanup function specific to restore
cleanup_restore() {
    cleanup "Restore process" "Restore"
    rm -rf "$TEMP_DIR"
}
trap cleanup_restore INT TERM

# Start restore process
log "INFO" "Starting restore process for $DIR"
update_status "STARTED" "Restore process for $DIR"

# Create temporary directory for extraction
TEMP_DIR="$SCRIPTPATH/temp_restore_$DIR"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR"
    check_status $? "Creating temporary directory" "Restore"
fi

# Restore database if requested
if [ "$RESTORE_DB" = true ] && [ -n "$DB_BACKUP" ]; then
    log "INFO" "Restoring database from $(basename "$DB_BACKUP")"
    echo -e "${CYAN}${BOLD}Restoring database...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        # Extract database backup
        cd "$TEMP_DIR" || exit 1
        
        # Determine compression format and extract accordingly
        if [[ "$DB_BACKUP" == *.zip ]]; then
            unzip -q "$DB_BACKUP"
            check_status $? "Extracting database backup" "Restore"
        elif [[ "$DB_BACKUP" == *.tar.gz ]]; then
            tar -xzf "$DB_BACKUP"
            check_status $? "Extracting database backup" "Restore"
        elif [[ "$DB_BACKUP" == *.tar ]]; then
            tar -xf "$DB_BACKUP"
            check_status $? "Extracting database backup" "Restore"
        else
            echo -e "${RED}${BOLD}Error: Unsupported compression format for $DB_BACKUP!${NC}" >&2
            exit 1
        fi
        
        # Find SQL file
        SQL_FILE=$(find . -name "*.sql" | head -n 1)
        
        if [ -z "$SQL_FILE" ]; then
            echo -e "${RED}${BOLD}Error: No SQL file found in database backup!${NC}" >&2
            exit 1
        fi
        
        # Import database
        wp db import "$SQL_FILE" --path="$wpPath"
        check_status $? "Importing database" "Restore"
        
        log "INFO" "Database restored successfully"
    else
        log "INFO" "Dry run: Skipping database restore"
    fi
fi

# Restore files if requested
if [ "$RESTORE_FILES" = true ] && [ -n "$FILES_BACKUP" ]; then
    log "INFO" "Restoring files from $(basename "$FILES_BACKUP")"
    echo -e "${CYAN}${BOLD}Restoring files...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        # Extract files backup
        cd "$TEMP_DIR" || exit 1
        
        # Determine compression format and extract accordingly
        if [[ "$FILES_BACKUP" == *.zip ]]; then
            unzip -q "$FILES_BACKUP"
            check_status $? "Extracting files backup" "Restore"
        elif [[ "$FILES_BACKUP" == *.tar.gz ]]; then
            tar -xzf "$FILES_BACKUP"
            check_status $? "Extracting files backup" "Restore"
        elif [[ "$FILES_BACKUP" == *.tar ]]; then
            tar -xf "$FILES_BACKUP"
            check_status $? "Extracting files backup" "Restore"
        else
            echo -e "${RED}${BOLD}Error: Unsupported compression format for $FILES_BACKUP!${NC}" >&2
            exit 1
        fi
        
        # Check if Files directory exists
        if [ -d "Files" ]; then
            # Create backup of current files
            CURRENT_BACKUP="$SCRIPTPATH/current_files_backup_$DIR"
            mkdir -p "$CURRENT_BACKUP"
            check_status $? "Creating backup of current files" "Restore"
            
            rsync -a "$wpPath/" "$CURRENT_BACKUP/"
            check_status $? "Backing up current files" "Restore"
            
            # Restore files
            rsync -a --delete "Files/" "$wpPath/"
            check_status $? "Restoring files" "Restore"
            
            log "INFO" "Files restored successfully"
            log "INFO" "Backup of previous files saved to $CURRENT_BACKUP"
        else
            echo -e "${RED}${BOLD}Error: Files directory not found in backup!${NC}" >&2
            exit 1
        fi
    else
        log "INFO" "Dry run: Skipping files restore"
    fi
fi

# Clean up
if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary files" "Restore"
fi

# Complete the restore process
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Restore process completed successfully in ${DURATION}s"
update_status "SUCCESS" "Restore process completed in ${DURATION}s"
notify "SUCCESS" "Restore process completed successfully in ${DURATION}s" "Restore"

echo -e "${GREEN}${BOLD}Restore completed successfully!${NC}"
echo -e "${GREEN}Time taken: ${NC}${DURATION} seconds"
