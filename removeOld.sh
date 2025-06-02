#!/bin/bash

################################################################################
# Script: remove_old.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description:
#   This script removes old backup files and logs based on retention duration,
#   available disk space, or a combination of these criteria.
#   It includes safety checks for paths, uses a lock file to prevent concurrent runs,
#   and supports dry run and verbose modes.
#
# Usage:
#   remove_old.sh -c <config_file> [-d] [-v] [--help|-h]
#
# Command line options:
#   -c <config_file>  : Path to the configuration file (required).
#   -d                : Dry run mode (simulate deletions).
#   -v                : Verbose output.
#   --help, -h        : Show help message and exit.
#
################################################################################

# Load common functions and variables
. "$(dirname "$0")/common.sh"

# --- Constants and Configuration ----------------------------------------------

# Directories allowed for deletion operations (safety list)
SAFE_PATHS=(
    "/var/backups"
    "/home/backup"
    "$SCRIPTPATH/backups"
    "$SCRIPTPATH/local_backups"
)

# Archive file extensions to target
ARCHIVE_EXTS=("zip" "tar" "tar.gz" "tgz" "gz" "bz2" "xz" "7z")

# Log files and sizes
LOG_FILE="$SCRIPTPATH/logs/remove_old.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/remove_old_status.log}"
MAX_LOG_SIZE=$((200 * 1024 * 1024)) # 200MB

# Defaults for options
DRY_RUN=false
VERBOSE=false

# Configuration variables (will be overridden by config file)
DISK_FREE_ENABLE="n"
DISK_MIN_FREE_GB=0
CLEANUP_MODE="time"

# --- Functions ----------------------------------------------------------------

## Show usage/help message and exit
usage() {
    echo -e "${GREEN}${BOLD}Professional WordPress Backup Old Files Remover${NC}"
    echo -e "Removes old backup files by time, disk space, or both criteria."
    echo -e "\n${GREEN}Usage: $0 -c <config_file> [-d] [-v] [--help|-h]${NC}"
    echo -e "  -c <config_file>     Path to the configuration file (required)."
    echo -e "  -d                   Dry run mode (simulates deletions)."
    echo -e "  -v                   Verbose output (detailed console messages)."
    echo -e "  --help, -h           Show this help message and exit."
    exit 0
}

## Retrieve free disk space in GiB for the filesystem of $fullPath
## Returns integer value of free space in GiB
get_disk_free_gb() {
    local free_space_gb
    free_space_gb=$(df -BG --output=avail "$fullPath" 2>/dev/null | tail -n 1 | tr -dc '0-9')
    if [ -z "$free_space_gb" ]; then
        log "WARNING" "Could not determine free disk space for '$fullPath'. Assuming 0 GB free."
        echo "0"
    else
        echo "$free_space_gb"
    fi
}

## Determine if a file should be deleted based on CLEANUP_MODE and disk space
## Args:
##   $1 - Path of the file to check
## Returns:
##   0 if the file should be deleted, 1 otherwise
should_delete_file() {
    local current_file_path="$1"
    local current_file_age_days
    local current_disk_free_gb

    case "$CLEANUP_MODE" in
        "time")
            # Files are already filtered by age in find command
            log "DEBUG" "Mode 'time': File '$current_file_path' selected for deletion."
            return 0
            ;;
        "space")
            if [ "$DISK_FREE_ENABLE" != "y" ]; then
                return 1
            fi
            current_disk_free_gb=$(get_disk_free_gb)
            if (( current_disk_free_gb < DISK_MIN_FREE_GB )); then
                log "DEBUG" "Mode 'space': Disk free ($current_disk_free_gb GB) < min ($DISK_MIN_FREE_GB GB); deleting file '$current_file_path'."
                return 0
            else
                log "DEBUG" "Mode 'space': Disk free ($current_disk_free_gb GB) >= min ($DISK_MIN_FREE_GB GB); stop deletions."
                return 1
            fi
            ;;
        "both")
            if [ "$DISK_FREE_ENABLE" != "y" ]; then
                return 1
            fi
            # Calculate file age in days
            current_file_age_days=$(( ( $(date +%s) - $(stat -c %Y "$current_file_path" 2>/dev/null || echo 0) ) / 86400 ))
            if (( current_file_age_days >= BACKUP_RETAIN_DURATION )); then
                current_disk_free_gb=$(get_disk_free_gb)
                if (( current_disk_free_gb < DISK_MIN_FREE_GB )); then
                    log "DEBUG" "Mode 'both': File '$current_file_path' is old and disk free ($current_disk_free_gb GB) < minimum."
                    return 0
                else
                    log "DEBUG" "Mode 'both': File '$current_file_path' is old but disk free ($current_disk_free_gb GB) sufficient; keeping."
                    return 1
                fi
            else
                log "DEBUG" "Mode 'both': File '$current_file_path' is not old enough ($current_file_age_days days); keeping."
                return 1
            fi
            ;;
        *)
            log "WARNING" "Unknown CLEANUP_MODE: '$CLEANUP_MODE'. No deletions performed."
            return 1
            ;;
    esac
    return 1
}

## Remove files from given list based on deletion criteria
## Args:
##   List of file paths as positional parameters
## Outputs:
##   echo "<number_of_deleted_files> <total_size_freed_in_bytes>"
remove_files_based_on_criteria() {
    local files_to_process_array=("${@}")
    local deleted_count=0
    local total_size_freed=0
    local current_file
    local file_size_bytes

    # For 'space' or 'both' with disk enabled, sort files by oldest first for deletion
    if [[ "$CLEANUP_MODE" == "space" ]] || { [[ "$CLEANUP_MODE" == "both" ]] && [[ "$DISK_FREE_ENABLE" == "y" ]]; }; then
        log "INFO" "Sorting files by oldest modification time for deletion mode '$CLEANUP_MODE'."
        local temp_sortable_array=()
        for current_file in "${files_to_process_array[@]}"; do
            if [ -f "$current_file" ]; then
                local timestamp
                timestamp=$(stat -c "%Y" "$current_file" 2>/dev/null)
                if [ -n "$timestamp" ]; then
                    temp_sortable_array+=("$timestamp $current_file")
                fi
            fi
        done
        # Sort by timestamp asc and extract filenames
        mapfile -t files_to_process_array < <(printf '%s\n' "${temp_sortable_array[@]}" | sort -n -k1,1 | cut -d' ' -f2-)
    fi

    for current_file in "${files_to_process_array[@]}"; do
        if [ ! -f "$current_file" ]; then
            log "DEBUG" "File '$current_file' no longer exists; skipping."
            continue
        fi

        if should_delete_file "$current_file"; then
            file_size_bytes=$(stat -c %s "$current_file" 2>/dev/null)
            file_size_bytes=${file_size_bytes:-0}

            if [ "$DRY_RUN" = false ]; then
                log "INFO" "Deleting file '$current_file' (Size: $(human_readable_size "$file_size_bytes")). Mode: $CLEANUP_MODE"
                if ! $QUIET; then
                    echo -e "${RED}Removing: $current_file ($(human_readable_size "$file_size_bytes"))${NC}"
                fi
                rm -f -- "$current_file"
                if [ $? -ne 0 ]; then
                    log "ERROR" "Failed to remove file '$current_file'."
                    continue
                fi
            else
                log "INFO" "[Dry Run] Would delete '$current_file' (Size: $(human_readable_size "$file_size_bytes")). Mode: $CLEANUP_MODE"
                if ! $QUIET; then
                    echo -e "${YELLOW}[Dry Run] Would remove: $current_file ($(human_readable_size "$file_size_bytes"))${NC}"
                fi
            fi

            ((deleted_count++))
            ((total_size_freed += file_size_bytes))

            # In space mode, check if target disk free achieved after each deletion
            if [[ "$CLEANUP_MODE" == "space" ]] && [[ "$DISK_FREE_ENABLE" == "y" ]]; then
                local current_disk_free_gb_after_del
                current_disk_free_gb_after_del=$(get_disk_free_gb)
                if (( current_disk_free_gb_after_del >= DISK_MIN_FREE_GB )); then
                    log "INFO" "Disk free target reached (${DISK_MIN_FREE_GB}GB). Stopping deletions."
                    break
                fi
            fi
        fi
    done

    echo "$deleted_count $total_size_freed"
}

# --- Parse Command Line Arguments ---------------------------------------------

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c) CONFIG_FILE="$2"; shift 2 ;;
        -d) DRY_RUN=true; shift ;;
        -v) VERBOSE=true; shift ;;
        --help|-h) usage ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage ;;
    esac
done

# --- Load and Validate Configuration ------------------------------------------

if [ -z "$CONFIG_FILE" ]; then
    log "ERROR" "Configuration file not specified. Use -c <config_file>."
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR" "Configuration file '$CONFIG_FILE' not found."
    exit 1
else
    . "$CONFIG_FILE"
    log "INFO" "Loaded configuration from '$CONFIG_FILE'."

    # Convert SAFE_PATHS from comma-separated string to array if needed
    if [[ "$SAFE_PATHS" == *,* ]]; then
        IFS=',' read -ra SAFE_PATHS <<< "$SAFE_PATHS"
        log "INFO" "Converted SAFE_PATHS string to array with ${#SAFE_PATHS[@]} elements."
    fi
fi

# Ensure config variables have defaults if unset
DISK_FREE_ENABLE="${DISK_FREE_ENABLE:-n}"
DISK_MIN_FREE_GB="${DISK_MIN_FREE_GB:-0}"
CLEANUP_MODE="${CLEANUP_MODE:-time}"

# Verify required variables from config
REQUIRED_CONFIG_VARS=("fullPath" "BACKUP_RETAIN_DURATION")
for var in "${REQUIRED_CONFIG_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log "ERROR" "Required variable '$var' not set in configuration."
        exit 1
    fi
done

# Validate that fullPath is within safe directories
FOUND_SAFE_PATH=0
for safe_dir in "${SAFE_PATHS[@]}"; do
    if [[ "$fullPath" == "$safe_dir"* ]]; then
        FOUND_SAFE_PATH=1
        break
    fi
done
if [ "$FOUND_SAFE_PATH" -ne 1 ]; then
    log "ERROR" "Target path '$fullPath' is not within allowed safe paths. Aborting."
    exit 2
fi
log "INFO" "Target path '$fullPath' verified within allowed safe paths."

# --- Setup Logging and Locking -----------------------------------------------

NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"

LOCK_FILE="/var/lock/remove_old_$(echo "$fullPath" | md5sum | cut -d' ' -f1).lock"
exec 9>"$LOCK_FILE" || { log "ERROR" "Cannot open lockfile '$LOCK_FILE'. Check permissions."; exit 10; }

if ! flock -n 9; then
    log "WARNING" "Another instance is running for path '$fullPath'. Exiting."
    exec 9>&-
    exit 7
fi
# Lock released on script exit by trap

# --- Cleanup Trap Handler ----------------------------------------------------

cleanup_remove_script() {
    cleanup "Old backups removal process (trap cleanup)" "Remove Old Script Cleanup"
    log "INFO" "Old backup removal script finished or interrupted."
    exec 9>&-
    log "DEBUG" "Lock file '$LOCK_FILE' released."
}
trap cleanup_remove_script EXIT INT TERM

# --- Main Script Execution ---------------------------------------------------

init_log "Old Backups/Logs Remover"

log "INFO" "Starting old file removal in '$fullPath'."
log "INFO" "Mode: $CLEANUP_MODE; Retain days: $BACKUP_RETAIN_DURATION; Disk min free: $DISK_MIN_FREE_GB GB (Enabled: $DISK_FREE_ENABLE)."
update_status "STARTED" "Removal of old backups/logs in '$fullPath'"

# Prepare find command patterns for archives
archive_find_pattern_parts=""
for ext in "${ARCHIVE_EXTS[@]}"; do
    archive_find_pattern_parts+="-o -iname \"*.$ext\" "
done
archive_find_pattern_parts="${archive_find_pattern_parts:3}" # Remove leading -o

if [[ "$CLEANUP_MODE" == "space" ]]; then
    FIND_CMD_ARCHIVES="find \"$fullPath\" -type f \( $archive_find_pattern_parts \)"
    FIND_CMD_LOGS="find \"$fullPath\" -type f -iname '*.log' -size +${MAX_LOG_SIZE}c"
else
    FIND_CMD_ARCHIVES="find \"$fullPath\" -type f \( $archive_find_pattern_parts \) -mtime +$BACKUP_RETAIN_DURATION"
    FIND_CMD_LOGS="find \"$fullPath\" -type f -iname '*.log' -mtime +$BACKUP_RETAIN_DURATION -size +${MAX_LOG_SIZE}c"
fi

total_archives_deleted_count=0
total_logs_deleted_count=0
total_archives_size_freed=0
total_logs_size_freed=0
candidate_archives_list=()
candidate_logs_list=()

# Record disk space before cleanup
DISK_SPACE_BEFORE_GB=$(get_disk_free_gb)
log "INFO" "Disk space before cleanup: ${DISK_SPACE_BEFORE_GB} GB."

# Find archive files matching criteria
mapfile -t candidate_archives_list < <(eval "$FIND_CMD_ARCHIVES" 2>/dev/null)

if [ "${#candidate_archives_list[@]}" -gt 0 ]; then
    log "INFO" "Found ${#candidate_archives_list[@]} archive files (candidates)."

    # Remove archive files based on criteria
    output_from_archive_func=$(remove_files_based_on_criteria "${candidate_archives_list[@]}")
    last_line_archives=$(echo "$output_from_archive_func" | tail -n 1)

    if [[ "$last_line_archives" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
        read -r total_archives_deleted_count total_archives_size_freed <<< "$last_line_archives"
    else
        log "ERROR" "Failed to parse output from archive deletion. Output: $output_from_archive_func"
        total_archives_deleted_count=0
        total_archives_size_freed=0
    fi

    log "INFO" "Archives processed. Deleted: $total_archives_deleted_count, Size freed: $(human_readable_size "$total_archives_size_freed")."
else
    log "INFO" "No archive files found."
fi

# Process log files if applicable
if [[ "$CLEANUP_MODE" == "time" || "$CLEANUP_MODE" == "both" ]]; then
    mapfile -t candidate_logs_list < <(eval "$FIND_CMD_LOGS" 2>/dev/null)
    if [ "${#candidate_logs_list[@]}" -gt 0 ]; then
        log "INFO" "Found ${#candidate_logs_list[@]} log files older than $BACKUP_RETAIN_DURATION days and larger than $(human_readable_size "$MAX_LOG_SIZE")."
        
        output_from_log_func=$(remove_files_based_on_criteria "${candidate_logs_list[@]}")
        last_line_logs=$(echo "$output_from_log_func" | tail -n 1)

        if [[ "$last_line_logs" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
            read -r total_logs_deleted_count total_logs_size_freed <<< "$last_line_logs"
        else
            log "ERROR" "Failed to parse output from log deletion. Output: $output_from_log_func"
            total_logs_deleted_count=0
            total_logs_size_freed=0
        fi

        log "INFO" "Logs processed. Deleted: $total_logs_deleted_count, Size freed: $(human_readable_size "$total_logs_size_freed")."
    else
        log "INFO" "No large, old log files found."
    fi
else
    log "INFO" "Skipping log cleanup for CLEANUP_MODE='$CLEANUP_MODE'."
fi

# Record disk space after cleanup
DISK_SPACE_AFTER_GB=$(get_disk_free_gb)
log "INFO" "Disk space after cleanup: ${DISK_SPACE_AFTER_GB} GB."

# Create summary report temporary file
SUMMARY_TEMP_FILE=$(mktemp)
{
    echo "Backup & Log Cleanup Summary"
    echo "============================"
    echo "Date: $(date)"
    echo "Host: $(hostname)"
    echo "Target Path: $fullPath"
    echo "Retention Period: $BACKUP_RETAIN_DURATION days"
    echo "Cleanup Mode: $CLEANUP_MODE"
    if [ "$DISK_FREE_ENABLE" == "y" ]; then
        echo "Minimum Disk Free Target: $DISK_MIN_FREE_GB GB"
    else
        echo "Disk Free Space Target: Disabled"
    fi
    echo ""
    echo "Archives Removed: $total_archives_deleted_count"
    echo "Size Freed from Archives: $(human_readable_size "$total_archives_size_freed")"
    echo "Log Files Removed: $total_logs_deleted_count"
    echo "Size Freed from Logs: $(human_readable_size "$total_logs_size_freed")"
    total_size_freed_combined=$((total_archives_size_freed + total_logs_size_freed))
    echo "Total Size Freed: $(human_readable_size "$total_size_freed_combined")"
    echo ""
    echo "Disk Free Before Cleanup: ${DISK_SPACE_BEFORE_GB} GB"
    echo "Disk Free After Cleanup:  ${DISK_SPACE_AFTER_GB} GB"
} > "$SUMMARY_TEMP_FILE"

# Determine notification status and message prefix
notify_status_type="INFO"
notify_message_prefix=""
if [ "$DRY_RUN" = true ]; then
    notify_message_prefix="[Dry Run] "
    notify_status_type="INFO"
else
    if [ "$total_archives_deleted_count" -gt 0 ] || [ "$total_logs_deleted_count" -gt 0 ]; then
        notify_status_type="SUCCESS"
    fi
fi

notify "$notify_status_type" \
       "${notify_message_prefix}Removed $total_archives_deleted_count archives and $total_logs_deleted_count logs from '$fullPath'. Freed $(human_readable_size "$total_size_freed_combined"). Mode: $CLEANUP_MODE." \
       "Backup Cleanup Report" \
       "$SUMMARY_TEMP_FILE"

# Finalize process
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration "$DURATION")

log "INFO" "Completed old files removal for '$fullPath' in ${FORMATTED_DURATION}."
update_status "SUCCESS" "Removed $total_archives_deleted_count archives, $total_logs_deleted_count logs from '$fullPath'. Freed $(human_readable_size "$total_size_freed_combined"). Duration: ${FORMATTED_DURATION}."

if ! $QUIET; then
    echo -e "\n${GREEN}${BOLD}--- Backup & Log Cleanup Summary ---${NC}"
    sed -e "s/^/  ${GREEN}/" -e "s/=/=/g" "$SUMMARY_TEMP_FILE"
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}"
fi

rm -f "$SUMMARY_TEMP_FILE"

exit 0