#!/bin/bash
# Script: backup_all.sh
# Description: Automates backup process for all projects defined in the configs directory.
# Usage: ./backup_all.sh [<config_dir>] [-v] [-d] [-h]
# Options:
#   <config_dir>  Directory containing configuration files (default: ./configs)
#   -v            Enable verbose logging
#   -d            Enable dry run mode (no actual backup, just simulation)
#   -h            Display this help message
# Author: Sayyed Jamal Ghasemi


# Include common functions and variables
. "$(dirname "$0")/common.sh"

# Define log and status files
LOG_FILE="$SCRIPTPATH/backup_all.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/backup_all_status.log}"

# Initialize variables
VERBOSE=false
DRY_RUN=false
CONFIG_DIR="${1:-$SCRIPTPATH/configs}"

# Define colors for output
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

# Function to display help message
display_help() {
    echo "${GREEN}Usage: $0 [<config_dir>] [-v] [-d] [-h]${RESET}"
    echo "Options:"
    echo "  <config_dir>  Directory containing configuration files (default: ./configs)"
    echo "  -v            Enable verbose logging"
    echo "  -d            Enable dry run mode (no actual backup, just simulation)"
    echo "  -h            Display this help message"
    exit 0
}

# Parse command-line options
while getopts "vdh" opt; do
    case $opt in
        v) VERBOSE=true;;
        d) DRY_RUN=true;;
        h) display_help;;
        ?) echo "${RED}Error: Invalid option. Usage: $0 [<config_dir>] [-v] [-d] [-h]${RESET}" >&2; exit 1;;
    esac
done

# Shift options to handle positional arguments
shift $((OPTIND-1))

# Override CONFIG_DIR if provided as positional argument
[ -n "$1" ] && CONFIG_DIR="$1"

# Check if config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
    echo "${RED}Error: Config directory $CONFIG_DIR does not exist!${RESET}" >&2
    log "ERROR" "Config directory $CONFIG_DIR does not exist!"
    update_status "FAILURE" "Config directory not found"
    notify "FAILURE" "Config directory $CONFIG_DIR not found" "Backup All"
    exit 1
fi

# Check if backup.sh script exists
if [ ! -f "$SCRIPTPATH/backup.sh" ]; then
    echo "${RED}Error: backup.sh not found in $SCRIPTPATH!${RESET}" >&2
    log "ERROR" "backup.sh not found in $SCRIPTPATH!"
    update_status "FAILURE" "backup.sh not found"
    notify "FAILURE" "backup.sh not found in $SCRIPTPATH" "Backup All"
    exit 1
fi

# Start backup process
echo "${GREEN}Starting backup process for all projects in $CONFIG_DIR${RESET}"
log "INFO" "Starting backup process for all projects in $CONFIG_DIR"
update_status "STARTED" "Backup process for all projects in $CONFIG_DIR"

# Initialize counters
SUCCESS_COUNT=0
FAILURE_COUNT=0

# Loop through all config files in the directory
for config in "$CONFIG_DIR"/*.conf; do
    if [ -f "$config" ]; then
        PROJECT_NAME=$(basename "$config" .conf)
        echo "${YELLOW}Backing up project: $PROJECT_NAME with config $config${RESET}"
        log "INFO" "Backing up project: $PROJECT_NAME with config $config"

        # Source the config file
        . "$config"

        # Build the backup command
        BACKUP_CMD="$SCRIPTPATH/backup.sh -c $config -b"
        [ "$VERBOSE" = true ] && BACKUP_CMD="$BACKUP_CMD -v"
        [ "$DRY_RUN" = true ] && BACKUP_CMD="$BACKUP_CMD -d"

        # Execute the backup command
        bash -c "$BACKUP_CMD"
        if [ $? -eq 0 ]; then
            echo "${GREEN}Backup for $PROJECT_NAME completed successfully${RESET}"
            log "INFO" "Backup for $PROJECT_NAME completed successfully"
            ((SUCCESS_COUNT++))
        else
            echo "${RED}Backup for $PROJECT_NAME failed${RESET}"
            log "ERROR" "Backup for $PROJECT_NAME failed"
            notify "FAILURE" "Backup for $PROJECT_NAME failed" "Backup All"
            ((FAILURE_COUNT++))
        fi
    else
        echo "${YELLOW}No config files found in $CONFIG_DIR${RESET}"
        log "INFO" "No config files found in $CONFIG_DIR"
        update_status "SUCCESS" "No projects to backup"
        notify "SUCCESS" "No projects to backup in $CONFIG_DIR" "Backup All"
        exit 0
    fi
done

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Log and notify completion
echo "${GREEN}Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s${RESET}"
log "INFO" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s"
update_status "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s"
notify "SUCCESS" "Backup process completed: $SUCCESS_COUNT successful, $FAILURE_COUNT failed in ${DURATION}s" "Backup All"

# Exit with error if there were failures
if [ "$FAILURE_COUNT" -gt 0 ]; then
    exit 1
fi