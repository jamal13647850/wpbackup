#!/bin/bash
. "$(dirname "$0")/common.sh"

LOG_FILE="$SCRIPTPATH/maintenance.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/maintenance_status.log}"

# Initialize variables with defaults
DRY_RUN=false
VERBOSE=false
CLEANUP_BACKUPS=false
OPTIMIZE_DB=false
REPAIR_DB=false
UPDATE_WP=false
UPDATE_PLUGINS=false
UPDATE_THEMES=false
SCAN_MALWARE=false
BACKUP_BEFORE=false
BACKUP_RETAIN_DAYS=30

# Parse command line options
while getopts "c:dvcorpatlsh" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true; LOG_LEVEL="verbose";;
        c) CLEANUP_BACKUPS=true;;
        o) OPTIMIZE_DB=true;;
        r) REPAIR_DB=true;;
        p) UPDATE_PLUGINS=true;;
        a) UPDATE_WP=true; UPDATE_PLUGINS=true; UPDATE_THEMES=true;;
        t) UPDATE_THEMES=true;;
        l) SCAN_MALWARE=true;;
        s) BACKUP_BEFORE=true;;
        h) 
            echo -e "${BLUE}${BOLD}WordPress Maintenance Script${NC}"
            echo -e "${CYAN}Usage:${NC} $0 [options]"
            echo -e "${CYAN}Options:${NC}"
            echo -e "  -c <config_file>     Configuration file"
            echo -e "  -d                   Dry run (no actual changes)"
            echo -e "  -v                   Verbose output"
            echo -e "  -c                   Cleanup old backups"
            echo -e "  -o                   Optimize database"
            echo -e "  -r                   Repair database"
            echo -e "  -p                   Update plugins"
            echo -e "  -a                   Update WordPress core, plugins, and themes"
            echo -e "  -t                   Update themes"
            echo -e "  -l                   Scan for malware"
            echo -e "  -s                   Create backup before maintenance"
            echo -e "  -h                   Show this help"
            exit 0
            ;;
        ?) 
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [options]" >&2
            exit 1
            ;;
    esac
done

# If no maintenance tasks are specified, show help
if [ "$CLEANUP_BACKUPS" = false ] && [ "$OPTIMIZE_DB" = false ] && [ "$REPAIR_DB" = false ] && \
   [ "$UPDATE_WP" = false ] && [ "$UPDATE_PLUGINS" = false ] && [ "$UPDATE_THEMES" = false ] && \
   [ "$SCAN_MALWARE" = false ]; then
    echo -e "${YELLOW}${BOLD}No maintenance tasks specified.${NC}"
    echo -e "${YELLOW}Use -h for help.${NC}"
    exit 1
fi

# If config file not specified, prompt for selection
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "maintenance"; then
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

# Set defaults for variables that might not be in config file
BACKUP_RETAIN_DURATION="${BACKUP_RETAIN_DURATION:-30}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"

# Cleanup function specific to maintenance
cleanup_maintenance() {
    cleanup "Maintenance process" "Maintenance"
}
trap cleanup_maintenance INT TERM

# Start maintenance process
log "INFO" "Starting maintenance process for $DIR"
update_status "STARTED" "Maintenance process for $DIR"

# Create backup before maintenance if requested
if [ "$BACKUP_BEFORE" = true ]; then
    log "INFO" "Creating backup before maintenance"
    echo -e "${CYAN}${BOLD}Creating backup before maintenance...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        "$SCRIPTPATH/backup.sh" -c "$CONFIG_FILE" -l
        check_status $? "Creating backup before maintenance" "Maintenance"
    else
        log "INFO" "Dry run: Skipping backup before maintenance"
    fi
fi

# Cleanup old backups if requested
if [ "$CLEANUP_BACKUPS" = true ]; then
    log "INFO" "Cleaning up old backups (older than $BACKUP_RETAIN_DURATION days)"
    echo -e "${CYAN}${BOLD}Cleaning up old backups...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        # Clean up local backups
        if [ -d "$LOCAL_BACKUP_DIR" ]; then
            find "$LOCAL_BACKUP_DIR" -type f \( -name "*.zip" -o -name "*.tar.gz" -o -name "*.tar" \) -mtime +$BACKUP_RETAIN_DURATION -exec rm -fv {} \;
            check_status $? "Cleaning up local backups" "Maintenance"
            log "INFO" "Local backups cleaned up successfully"
        fi
        
        # Clean up remote backups if remote backup is configured
        if [ -n "$destinationUser" ] && [ -n "$destinationIP" ] && [ -n "$destinationDbBackupPath" ] && [ -n "$destinationFilesBackupPath" ]; then
            log "INFO" "Cleaning up remote backups"
            ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "find $destinationDbBackupPath -type f \( -name \"*.zip\" -o -name \"*.tar.gz\" -o -name \"*.tar\" \) -mtime +$BACKUP_RETAIN_DURATION -exec rm -fv {} \;"
            check_status $? "Cleaning up remote DB backups" "Maintenance"
            
            ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "find $destinationFilesBackupPath -type f \( -name \"*.zip\" -o -name \"*.tar.gz\" -o -name \"*.tar\" \) -mtime +$BACKUP_RETAIN_DURATION -exec rm -fv {} \;"
            check_status $? "Cleaning up remote files backups" "Maintenance"
            
            log "INFO" "Remote backups cleaned up successfully"
        fi
    else
        log "INFO" "Dry run: Skipping backup cleanup"
    fi
fi

# Optimize database if requested
if [ "$OPTIMIZE_DB" = true ]; then
    log "INFO" "Optimizing database"
    echo -e "${CYAN}${BOLD}Optimizing database...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        wp db optimize --path="$wpPath"
        check_status $? "Optimizing database" "Maintenance"
        log "INFO" "Database optimized successfully"
    else
        log "INFO" "Dry run: Skipping database optimization"
    fi
fi

# Repair database if requested
if [ "$REPAIR_DB" = true ]; then
    log "INFO" "Repairing database"
    echo -e "${CYAN}${BOLD}Repairing database...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        wp db repair --path="$wpPath"
        check_status $? "Repairing database" "Maintenance"
        log "INFO" "Database repaired successfully"
    else
        log "INFO" "Dry run: Skipping database repair"
    fi
fi

# Update WordPress core if requested
if [ "$UPDATE_WP" = true ]; then
    log "INFO" "Updating WordPress core"
    echo -e "${CYAN}${BOLD}Updating WordPress core...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        wp core update --path="$wpPath"
        check_status $? "Updating WordPress core" "Maintenance"
        
        wp core update-db --path="$wpPath"
        check_status $? "Updating WordPress database" "Maintenance"
        
        log "INFO" "WordPress core updated successfully"
    else
        log "INFO" "Dry run: Skipping WordPress core update"
    fi
fi

# Update plugins if requested
if [ "$UPDATE_PLUGINS" = true ]; then
    log "INFO" "Updating plugins"
    echo -e "${CYAN}${BOLD}Updating plugins...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        wp plugin update --all --path="$wpPath"
        check_status $? "Updating plugins" "Maintenance"
        log "INFO" "Plugins updated successfully"
    else
        log "INFO" "Dry run: Skipping plugin updates"
    fi
fi

# Update themes if requested
if [ "$UPDATE_THEMES" = true ]; then
    log "INFO" "Updating themes"
    echo -e "${CYAN}${BOLD}Updating themes...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        wp theme update --all --path="$wpPath"
        check_status $? "Updating themes" "Maintenance"
        log "INFO" "Themes updated successfully"
    else
        log "INFO" "Dry run: Skipping theme updates"
    fi
fi

# Scan for malware if requested
if [ "$SCAN_MALWARE" = true ]; then
    log "INFO" "Scanning for malware"
    echo -e "${CYAN}${BOLD}Scanning for malware...${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        # Check if ClamAV is installed
        if command_exists clamscan; then
            echo -e "${CYAN}Using ClamAV for malware scanning...${NC}"
            clamscan -r --infected --detect-pua=yes --exclude-dir="^/wp-content/cache" "$wpPath"
            scan_status=$?
            
            if [ $scan_status -eq 0 ]; then
                log "INFO" "No malware found"
                echo -e "${GREEN}${BOLD}No malware found!${NC}"
            elif [ $scan_status -eq 1 ]; then
                log "WARNING" "Malware found during scan"
                echo -e "${RED}${BOLD}Malware found! Check the scan results above.${NC}"
            else
                log "ERROR" "Error during malware scan"
                echo -e "${RED}${BOLD}Error during malware scan!${NC}"
            fi
        else
            # If ClamAV is not installed, use a simple pattern-based scan
            echo -e "${YELLOW}ClamAV not installed. Using simple pattern-based scan...${NC}"
            log "WARNING" "ClamAV not installed, using simple pattern-based scan"
            
            # Define patterns to search for
            PATTERNS=("eval(base64_decode" "base64_decode(strtr" "<script>eval" "eval(gzinflate" "shell_exec" "passthru" "system(" "exec(" "pcntl_exec" "popen" "proc_open")
            
            # Search for suspicious patterns
            SUSPICIOUS_FILES=()
            for pattern in "${PATTERNS[@]}"; do
                while IFS= read -r file; do
                    SUSPICIOUS_FILES+=("$file")
                done < <(grep -l "$pattern" $(find "$wpPath" -type f -name "*.php" | grep -v "wp-includes" | grep -v "wp-admin"))
            done
            
            # Report findings
            if [ ${#SUSPICIOUS_FILES[@]} -gt 0 ]; then
                log "WARNING" "Found ${#SUSPICIOUS_FILES[@]} suspicious files"
                echo -e "${RED}${BOLD}Found ${#SUSPICIOUS_FILES[@]} suspicious files:${NC}"
                for file in "${SUSPICIOUS_FILES[@]}"; do
                    echo -e "${RED}- $file${NC}"
                done
            else
                log "INFO" "No suspicious patterns found"
                echo -e "${GREEN}${BOLD}No suspicious patterns found!${NC}"
            fi
        fi
    else
        log "INFO" "Dry run: Skipping malware scan"
    fi
fi

# Complete the maintenance process
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Maintenance process completed successfully in ${DURATION}s"
update_status "SUCCESS" "Maintenance process completed in ${DURATION}s"
notify "SUCCESS" "Maintenance process completed successfully in ${DURATION}s" "Maintenance"

echo -e "${GREEN}${BOLD}Maintenance completed successfully!${NC}"
echo -e "${GREEN}Time taken: ${NC}${DURATION} seconds"
