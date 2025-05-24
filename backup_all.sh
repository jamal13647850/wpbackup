#!/bin/bash
#
# Script: backup_all.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Backup all WordPress sites defined in configuration files.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific log files ---
LOG_FILE="$SCRIPTPATH/logs/backup_all.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/backup_all_status.log}"

# --- Default values ---
VERBOSE=false
DRY_RUN=false
CONFIG_DIR="${1:-$SCRIPTPATH/configs}" # Default config directory
PARALLEL_JOBS=1                       # Number of parallel backup jobs
BACKUP_TYPE="full"                    # Default backup type (full, db, files)
INCREMENTAL=false                     # Use incremental backup for files
NOTIFY=true                           # Enable notifications by default
QUIET=false                           # Disable quiet mode by default

# Function to display help message
display_help() {
    echo -e "${GREEN}${BOLD}Usage:${NC} $0 [<config_dir>] [-v] [-d] [-p <jobs>] [-t <type>] [-i] [-n] [-q] [-h]"
    echo -e "Options:"
    echo -e "  <config_dir>    Directory containing configuration files (default: $SCRIPTPATH/configs)"
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
            display_help # Show help on invalid option
            ;;
    esac
done

# Shift processed options to access positional arguments
shift $((OPTIND-1))

# Override config directory if provided as a positional argument
[ -n "$1" ] && CONFIG_DIR="$1"

# Initialize log for this script
init_log "WordPress Backup All"

# Validate backup type
if [[ ! "$BACKUP_TYPE" =~ ^(full|db|files)$ ]]; then
    echo -e "${RED}${BOLD}Error: Invalid backup type '$BACKUP_TYPE'. Must be 'full', 'db', or 'files'.${NC}" >&2
    log "ERROR" "Invalid backup type '$BACKUP_TYPE'"
    update_status "FAILURE" "Invalid backup type specified"
    [ "$NOTIFY" = true ] && notify "FAILURE" "Invalid backup type '$BACKUP_TYPE'" "Backup All"
    exit 1
fi

# Validate number of parallel jobs
if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}${BOLD}Error: Invalid number of parallel jobs '$PARALLEL_JOBS'. Must be a positive integer.${NC}" >&2
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

# Check if backup.sh script exists and is executable
if [ ! -x "$SCRIPTPATH/backup.sh" ]; then # Also check for executable permission
    echo -e "${RED}${BOLD}Error: backup.sh not found or not executable in $SCRIPTPATH!${NC}" >&2
    log "ERROR" "backup.sh not found or not executable in $SCRIPTPATH!"
    update_status "FAILURE" "backup.sh not found or not executable"
    [ "$NOTIFY" = true ] && notify "FAILURE" "backup.sh not found or not executable in $SCRIPTPATH" "Backup All"
    exit 1
fi

# Function for cleanup operations specific to this script
cleanup_backup_all() {
    cleanup "Backup All process" "Backup All" # Call common cleanup
    rm -f "$SCRIPTPATH/.backup_results"       # Remove temporary results file
}
trap cleanup_backup_all EXIT INT TERM # Ensure cleanup runs on script exit or interruption

# Start backup process
if [ "$QUIET" = false ]; then
    echo -e "${GREEN}${BOLD}Starting backup process for all projects in $CONFIG_DIR${NC}"
fi
log "INFO" "Starting backup process for all projects in $CONFIG_DIR. Parallel jobs: $PARALLEL_JOBS, Type: $BACKUP_TYPE"
update_status "STARTED" "Backup process for all projects in $CONFIG_DIR"

# Count configuration files (.conf and .conf.gpg)
CONFIG_FILES_FIND_CMD="find \"$CONFIG_DIR\" -maxdepth 1 \( -name \"*.conf\" -o -name \"*.conf.gpg\" \) -type f"
CONFIG_COUNT=$(eval "$CONFIG_FILES_FIND_CMD" | wc -l)


if [ "$CONFIG_COUNT" -eq 0 ]; then
    if [ "$QUIET" = false ]; then
        echo -e "${YELLOW}${BOLD}No config files found in $CONFIG_DIR${NC}"
    fi
    log "INFO" "No config files found in $CONFIG_DIR"
    update_status "SUCCESS" "No projects to backup"
    [ "$NOTIFY" = true ] && notify "SUCCESS" "No projects to backup in $CONFIG_DIR" "Backup All"
    exit 0
fi

if [ "$QUIET" = false ]; then
    echo -e "${CYAN}${BOLD}Found $CONFIG_COUNT configuration files${NC}"
fi
log "INFO" "Found $CONFIG_COUNT configuration files"

# Initialize counters for backup results
SUCCESS_COUNT=0
FAILURE_COUNT=0
SKIPPED_COUNT=0 # Typically, a skip would mean a config file was found but not processed for some reason.

# Temporary file to store results from individual backup jobs
RESULTS_FILE="$SCRIPTPATH/.backup_results"
rm -f "$RESULTS_FILE"
touch "$RESULTS_FILE"

# Function to process a single backup job
process_backup() {
    local config_file="$1"
    # Extract project name from config file name (e.g., site1.conf or site1.conf.gpg -> site1)
    local project_name=$(basename "$config_file" | sed -E 's/\.conf(\.gpg)?$//')

    if [ "$QUIET" = false ]; then
        echo -e "${YELLOW}${BOLD}Starting backup for project: $project_name (Config: $config_file)${NC}"
    fi
    log "INFO" "Starting backup for project: $project_name (Config: $config_file)"

    # Construct the command to run backup.sh for the individual site
    local backup_script_cmd="$SCRIPTPATH/backup.sh -c \"$config_file\" -t \"$BACKUP_TYPE\""
    # Append optional flags
    [ "$VERBOSE" = true ] && backup_script_cmd="$backup_script_cmd -v"
    [ "$DRY_RUN" = true ] && backup_script_cmd="$backup_script_cmd -d"
    [ "$INCREMENTAL" = true ] && backup_script_cmd="$backup_script_cmd -i"
    [ "$QUIET" = true ] && backup_script_cmd="$backup_script_cmd -q" # Pass quiet mode to sub-script
                                                                # -b (batch) flag is assumed to be handled by backup.sh if -c is present

    local output
    if output=$(eval "$backup_script_cmd" 2>&1); then
        if [ "$QUIET" = false ]; then
            echo -e "${GREEN}${BOLD}Backup for $project_name completed successfully${NC}"
        fi
        log "INFO" "Backup for $project_name completed successfully."
        echo "$project_name:SUCCESS" >> "$RESULTS_FILE"
    else
        if [ "$QUIET" = false ]; then
            echo -e "${RED}${BOLD}Backup for $project_name FAILED:${NC}"
            # Indent output from failed script for readability
            echo "$output" | sed 's/^/  /' >&2
        fi
        log "ERROR" "Backup for $project_name FAILED. Output: $output"
        # Notification for individual failure can be noisy if many fail; primary notification is at the end.
        # However, keeping it for immediate alert on a specific project failure.
        [ "$NOTIFY" = true ] && notify "FAILURE" "Backup for project $project_name FAILED." "Backup All Details"
        echo "$project_name:FAILURE" >> "$RESULTS_FILE"
    fi
}

export -f process_backup # Export function for xargs or parallel if they spawn new shells
export SCRIPTPATH LOG_FILE STATUS_LOG VERBOSE DRY_RUN INCREMENTAL QUIET BACKUP_TYPE NOTIFY # Export necessary vars

# Process backups based on PARALLEL_JOBS setting
if [ "$PARALLEL_JOBS" -eq 1 ]; then
    if [ "$QUIET" = false ]; then
        echo -e "${CYAN}Running backups sequentially...${NC}"
    fi
    log "INFO" "Running backups sequentially."
    eval "$CONFIG_FILES_FIND_CMD" | while read -r config; do
        process_backup "$config"
    done
else
    if [ "$QUIET" = false ]; then
        echo -e "${CYAN}${BOLD}Running backups in parallel with $PARALLEL_JOBS jobs${NC}"
    fi
    log "INFO" "Running backups in parallel with $PARALLEL_JOBS jobs."
    # Using xargs for parallel processing
    eval "$CONFIG_FILES_FIND_CMD" | xargs -P "$PARALLEL_JOBS" -I {} bash -c "process_backup \"{}\""
fi

# Wait for all background jobs to complete (especially if not using xargs's -P or a manual job control loop)
wait # Important if the parallel method used backgrounding directly without xargs

# Count results from the temporary file
if [ -f "$RESULTS_FILE" ]; then
    SUCCESS_COUNT=$(grep -c ":SUCCESS$" "$RESULTS_FILE")
    FAILURE_COUNT=$(grep -c ":FAILURE$" "$RESULTS_FILE")
    # SKIPPED_COUNT needs more complex logic if we define what "skipped" means (e.g. config found but not processed)
    # For now, total configs - success - failure might not accurately be "skipped" unless all configs are attempted.
    # Assuming all found configs were attempted:
    ATTEMPTED_COUNT=$((SUCCESS_COUNT + FAILURE_COUNT))
    if [ "$CONFIG_COUNT" -ge "$ATTEMPTED_COUNT" ]; then
        SKIPPED_COUNT=$((CONFIG_COUNT - ATTEMPTED_COUNT)) # Configs found but not resulting in SUCCESS/FAILURE (e.g., if xargs/find had issues)
    else
        SKIPPED_COUNT=0 # Or handle as an anomaly
    fi
fi

# Calculate execution time and report
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME)) # START_TIME is expected to be set in common.sh
FORMATTED_DURATION=$(format_duration $DURATION)

if [ "$QUIET" = false ]; then
    echo -e "${GREEN}${BOLD}Backup process completed:${NC}"
    echo -e "  ${GREEN}Successful:${NC} $SUCCESS_COUNT"
    echo -e "  ${RED}Failed:${NC}     $FAILURE_COUNT"
    if [ "$SKIPPED_COUNT" -gt 0 ]; then # Only show skipped if there are any
        echo -e "  ${YELLOW}Skipped:${NC}    $SKIPPED_COUNT"
    fi
    echo -e "  ${CYAN}Time taken:${NC} ${FORMATTED_DURATION}"
fi

log "INFO" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped." # Duration is in log

if [ "$NOTIFY" = true ]; then
    SUMMARY_MSG="Backup All: $SUCCESS_COUNT successful, $FAILURE_COUNT failed, $SKIPPED_COUNT skipped. Duration: ${FORMATTED_DURATION}"
    if [ "$FAILURE_COUNT" -gt 0 ]; then
        notify "FAILURE" "$SUMMARY_MSG" "Backup All Report"
    else
        notify "SUCCESS" "$SUMMARY_MSG" "Backup All Report"
    fi
fi

# Exit with failure code if any backup failed
if [ "$FAILURE_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0