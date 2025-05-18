#!/bin/bash
# backup_all.sh - Backup all WordPress sites defined in configuration files
# Author: System Administrator
# Last updated: 2025-05-17

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/logs/backup_all.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/backup_all_status.log}"

# Initialize default values
VERBOSE=false
DRY_RUN=false
CONFIG_DIR="${1:-$SCRIPTPATH/configs}"
PARALLEL_JOBS=1
BACKUP_TYPE="full"
INCREMENTAL=false
NOTIFY=true
QUIET=false

# Function to display help message
display_help() {
    echo -e "${GREEN}${BOLD}Usage:${NC} $0 [<config_dir>] [-v] [-d] [-p <jobs>] [-t <type>] [-i] [-n] [-q] [-h]"
    echo -e "Options:"
    echo -e "  <config_dir>    Directory containing configuration files (default: ./configs)"
    echo -e "  -v              Enable verbose logging"
    echo -e "  -d              Enable dry run mode (no actual backup, just simulation)"
    echo -e "  -p <jobs>       Number of parallel backup jobs (default: 1)"
    echo -e "  -t <type>       Backup type: full, db, files (default: full)"
    echo -e "  -i              Use incremental backup for files"
    echo -e "  -n              Disable notifications"
    echo -e "  -q              Quiet mode (minimal output)"
    echo -e "  -h              Display this help message"
    exit 0
}

# Parse command line options
while getopts "vdp:t:inqh" opt; do
    case $opt in
        v) VERBOSE=true;;
        d) DRY_RUN=true;;
        p) PARALLEL_JOBS="$OPTARG";;
        t) BACKUP_TYPE="$OPTARG";;
        i) INCREMENTAL=true;;
        n) NOTIFY=false;;
        q) QUIET=true;;
        h) display_help;;
        ?) 
            echo -e "${RED}${BOLD}Error: Invalid option.${NC}" >&2
            display_help
            ;;
    esac
done

# Shift to handle non-option arguments
shift $((OPTIND-1))

# If first argument is provided, use it as config directory
[ -n "$1" ] && CONFIG_DIR="$1"

# Initialize log
init_log "WordPress Backup All"

# Validate backup type
if [[ ! "$BACKUP_TYPE" =~ ^(full|db|files)$ ]]; then
    echo -e "${RED}${BOLD}Error: Invalid backup type '$BACKUP_TYPE'. Must be 'full', 'db', or 'files'.${NC}" >&2
    log "ERROR" "Invalid backup type '$BACKUP_TYPE'"
    update_status "FAILURE" "Invalid backup type specified"
    [ "$NOTIFY" = true ] && notify "FAILURE" "Invalid backup type '$BACKUP_TYPE'" "Backup All"
    exit 1
fi

# Validate parallel jobs
if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}${BOLD}Error: Invalid number of parallel jobs '$PARALLEL_JOBS'.${NC}" >&2
    log "ERROR" "Invalid number of parallel jobs '$PARALLEL_JOBS'"
    update_status "FAILURE" "Invalid number of parallel jobs"
    [ "$NOTIFY" = true ] && notify "FAILURE" "Invalid number of parallel jobs '$PARALLEL_JOBS'" "Backup All"
    exit 1
fi

# Check if config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
    echo -e "${RED}${BOLD}Error: Config directory $CONFIG_DIR does not exist!${NC}" >&2
    log "ERROR" "Config directory $CONFIG_DIR does not exist!"
    update_status "FAILURE" "Config directory not found"
    [ "$NOTIFY" = true ] && notify "FAILURE" "Config directory $CONFIG_DIR not found" "Backup All"
    exit 1
fi

# Check if backup.sh exists
if [ ! -f "$SCRIPTPATH/backup.sh" ]; then
    echo -e "${RED}${BOLD}Error: backup.sh not found in $SCRIPTPATH!${NC}" >&2
    log "ERROR" "backup.sh not found in $SCRIPTPATH!"
    update_status "FAILURE" "backup.sh not found"
    [ "$NOTIFY" = true ] && notify "FAILURE" "backup.sh not found in $SCRIPTPATH" "Backup All"
    exit 1
fi

# Function for cleanup operations
cleanup_backup_all() {
    cleanup "Backup All process" "Backup All"
}
trap cleanup_backup_all INT TERM

# Start backup process
echo -e "${GREEN}${BOLD}Starting backup process for all projects in $CONFIG_DIR${NC}"
log "INFO" "Starting backup process for all projects in $CONFIG_DIR"
update_status "STARTED" "Backup process for all projects in $CONFIG_DIR"

# Count configuration files
CONFIG_COUNT=$(find "$CONFIG_DIR" -name "*.conf" -o -name "*.conf.gpg" | wc -l)

if [ "$CONFIG_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}No config files found in $CONFIG_DIR${NC}"
    log "INFO" "No config files found in $CONFIG_DIR"
    update_status "SUCCESS" "No projects to backup"
    [ "$NOTIFY" = true ] && notify "SUCCESS" "No projects to backup in $CONFIG_DIR" "Backup All"
    exit 0
fi

echo -e "${CYAN}${BOLD}Found $CONFIG_COUNT configuration files${NC}"
log "INFO" "Found $CONFIG_COUNT configuration files"

# Initialize counters
SUCCESS_COUNT=0
FAILURE_COUNT=0
SKIPPED_COUNT=0

# Function to process a single backup
process_backup() {
    local config="$1"
    local project_name=$(basename "$config" | sed 's/\.conf\(\.gpg\)\?$//')
    
    if [ "$QUIET" = false ]; then
        echo -e "${YELLOW}${BOLD}Backing up project: $project_name with config $config${NC}"
    fi
    log "INFO" "Backing up project: $project_name with config $config"
    
    # Build backup command
    BACKUP_CMD="$SCRIPTPATH/backup.sh -c $config -b -t $BACKUP_TYPE"
    [ "$VERBOSE" = true ] && BACKUP_CMD="$BACKUP_CMD -v"
    [ "$DRY_RUN" = true ] && BACKUP_CMD="$BACKUP_CMD -d"
    [ "$INCREMENTAL" = true ] && BACKUP_CMD="$BACKUP_CMD -i"
    [ "$QUIET" = true ] && BACKUP_CMD="$BACKUP_CMD -q"
    
    # Run backup command and capture output
    local output
    if output=$(bash -c "$BACKUP_CMD" 2>&1); then
        if [ "$QUIET" = false ]; then
            echo -e "${GREEN}${BOLD}Backup for $project_name completed successfully${NC}"
        fi
        log "INFO" "Backup for $project_name completed successfully"
        echo "$project_name:SUCCESS" >> "$SCRIPTPATH/.backup_results"
    else
        if [ "$QUIET" = false ]; then
            echo -e "${RED}${BOLD}Backup for $project_name failed:${NC}"
            echo -e "${output}"
        fi
        log "ERROR" "Backup for $project_name failed: $output"
        [ "$NOTIFY" = true ] && notify "FAILURE" "Backup for $project_name failed" "Backup All"
        echo "$project_name:FAILURE" >> "$SCRIPTPATH/.backup_results"
    fi
}

# Create temporary file for results
rm -f "$SCRIPTPATH/.backup_results"
touch "$SCRIPTPATH/.backup_results"

# Process backups based on parallel jobs setting
if [ "$PARALLEL_JOBS" -eq 1 ]; then
    # Sequential processing
    for config in "$CONFIG_DIR"/*.conf "$CONFIG_DIR"/*.conf.gpg; do
        if [ -f "$config" ]; then
            process_backup "$config"
        fi
    done
else
    # Parallel processing
    echo -e "${CYAN}${BOLD}Running backups in parallel with $PARALLEL_JOBS jobs${NC}"
    log "INFO" "Running backups in parallel with $PARALLEL_JOBS jobs"
    
    # Find all config files
    find "$CONFIG_DIR" -name "*.conf" -o -name "*.conf.gpg" | while read -r config; do
        if [ -f "$config" ]; then
            # Run in background and limit concurrent jobs
            while [ "$(jobs -r | wc -l)" -ge "$PARALLEL_JOBS" ]; do
                sleep 1
            done
            process_backup "$config" &
        fi
    done
    
    # Wait for all background jobs to complete
    wait
fi

# Count results
if [ -f "$SCRIPTPATH/.backup_results" ]; then
    SUCCESS_COUNT=$(grep -c ":SUCCESS$" "$SCRIPTPATH/.backup_results")
    FAILURE_COUNT=$(grep -c ":FAILURE$" "$SCRIPTPATH/.backup_results")
    SKIPPED_COUNT=$((CONFIG_COUNT - SUCCESS_COUNT - FAILURE_COUNT))
    rm -f "$SCRIPTPATH/.backup_results"
fi

# Calculate execution time and report
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)

echo -e "${GREEN}${BOLD}Backup process completed:${NC}"
echo -e "  ${GREEN}Successful:${NC} $SUCCESS_COUNT"
echo -e "  ${RED}Failed:${NC} $FAILURE_COUNT"
echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED_COUNT"
echo -e "  ${CYAN}Time taken:${NC} ${FORMATTED_DURATION}"

log "INFO" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped in ${FORMATTED_DURATION}"

if [ "$NOTIFY" = true ]; then
    notify "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped in ${FORMATTED_DURATION}" "Backup All"
fi

# Exit with failure if any backup failed
if [ "$FAILURE_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
