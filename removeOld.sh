#!/bin/bash
#
# Script: remove_old.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Removes old backup files and logs based on retention duration,
#              available disk space, or a combination of both criteria.
#              Includes safety checks for paths and uses a lock file.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script Constants and Configuration ---
# Define paths considered safe for automated deletion operations.
SAFE_PATHS=("/var/backups" "/home/backup" "$SCRIPTPATH/backups" "$SCRIPTPATH/local_backups") # Added local_backups
# Define common archive extensions to look for.
ARCHIVE_EXTS=("zip" "tar" "tar.gz" "tgz" "gz" "bz2" "xz" "7z")

LOG_FILE="$SCRIPTPATH/logs/remove_old.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/remove_old_status.log}"
MAX_LOG_SIZE=$((200 * 1024 * 1024)) # 200MB max size for old log files before considering deletion (if also old)

DRY_RUN=false
VERBOSE=false

# --- Configuration fields (to be set by the .conf file) ---
# DISK_FREE_ENABLE: "y" or "n" - whether to consider disk free space for cleanup.
# DISK_MIN_FREE_GB: integer - minimum free disk space in GB to maintain (if DISK_FREE_ENABLE is "y").
# CLEANUP_MODE: "time" | "space" | "both"
#   "time": Delete files older than BACKUP_RETAIN_DURATION.
#   "space": Delete oldest files until DISK_MIN_FREE_GB is met (ignores retention duration).
#   "both": Delete files older than BACKUP_RETAIN_DURATION *only if* free space is below DISK_MIN_FREE_GB.
# fullPath: The directory path to clean up.
# BACKUP_RETAIN_DURATION: Number of days to retain files.
DISK_FREE_ENABLE="n"    # Default value, to be overridden by config
DISK_MIN_FREE_GB=0      # Default value, to be overridden by config
CLEANUP_MODE="time"     # Default value, to be overridden by config

# --- Show usage/help function ---
usage() {
    echo -e "${GREEN}${BOLD}Professional WordPress Backup Old Files Remover${NC}"
    echo -e "Removes old backup files by time, disk space, or both criteria."
    echo -e "\n${GREEN}Usage: $0 -c <config_file> [-d] [-v] [--help|-h]${NC}"
    echo -e "  -c <config_file>     Path to the configuration file (required)."
    echo -e "  -d                   Dry run mode (simulates deletions, no actual files removed)."
    echo -e "  -v                   Verbose output (more detailed console messages)."
    echo -e "  --help, -h           Show this help message and exit."
    exit 0
}

# --- Parse command line options ---
# This script uses a custom loop for parsing, allowing GNU-style --help.
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c) CONFIG_FILE="$2"; shift 2 ;; # Config file path
        -d) DRY_RUN=true; shift ;;       # Dry run flag
        -v) VERBOSE=true; shift ;;       # Verbose flag
        --help|-h) usage ;;              # Display help
        *) echo -e "${RED}Unknown option: $1${NC}"; usage ;; # Unknown option
    esac
done

# --- Load and Validate Configuration ---
if [ -z "$CONFIG_FILE" ]; then
    log "ERROR" "Configuration file not specified. Use -c <config_file>."
    # usage function called by the parser for unknown/missing mandatory options.
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR" "Configuration file '$CONFIG_FILE' not found."
    exit 1
else
    # Source the configuration file. Variables within will be set in this script's scope.
    . "$CONFIG_FILE"
    log "INFO" "Successfully loaded configuration from '$CONFIG_FILE'."
fi

# Set defaults for new configuration options if they were not in the loaded config file.
DISK_FREE_ENABLE="${DISK_FREE_ENABLE:-n}"
DISK_MIN_FREE_GB="${DISK_MIN_FREE_GB:-0}"
CLEANUP_MODE="${CLEANUP_MODE:-time}" # Valid modes: time, space, both

# Validate essential variables from the config file.
REQUIRED_CONFIG_VARS=("fullPath" "BACKUP_RETAIN_DURATION")
for var_name in "${REQUIRED_CONFIG_VARS[@]}"; do
    if [ -z "${!var_name}" ]; then # Indirect variable expansion to check value
        log "ERROR" "Required variable '$var_name' is not set in '$CONFIG_FILE'."
        exit 1
    fi
done

# Security check: Ensure fullPath is within one of the predefined safe parent directories.
FOUND_SAFE_PATH=0
for safe_dir_pattern in "${SAFE_PATHS[@]}"; do
    # Check if fullPath starts with one of the safe_dir_patterns
    if [[ "$fullPath" == "$safe_dir_pattern"* ]]; then
        FOUND_SAFE_PATH=1
        break
    fi
done
if [ "$FOUND_SAFE_PATH" -ne 1 ]; then
    log "ERROR" "The target path '$fullPath' is not within the allowed safe paths defined in SAFE_PATHS. Aborting for safety."
    exit 2 # Exit with a specific code for path safety failure.
fi
log "INFO" "Target path '$fullPath' is within allowed safe paths."

# Set operational variables (LOG_LEVEL from common.sh based on -v)
NICE_LEVEL="${NICE_LEVEL:-19}" # Default niceness for commands
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}" # Default log level

# --- Lock File Implementation ---
# Prevents multiple instances of this script from running simultaneously on the same target.
LOCK_FILE="/var/lock/remove_old_$(echo "$fullPath" | md5sum | cut -d' ' -f1).lock" # Unique lock per path
exec 9>"$LOCK_FILE" || { log "ERROR" "Could not open lockfile '$LOCK_FILE'. Check permissions or if path is valid."; exit 10; }
# Attempt to acquire an exclusive, non-blocking lock.
if ! flock -n 9; then
    log "WARNING" "Another instance of remove_old.sh is already running for path '$fullPath' (Lock: '$LOCK_FILE'). Exiting."
    # Close file descriptor 9 before exiting
    exec 9>&-
    exit 7 # Exit code 7 indicates another instance is running.
fi
# If lock acquired, it will be released automatically when fd 9 is closed (on script exit).

# --- Cleanup Function for Trap ---
cleanup_remove_script() {
    # Call common cleanup if it performs generic tasks useful here
    cleanup "Old backups removal process (invoked by trap)" "Remove Old Script Cleanup"
    log "INFO" "Old backups removal script finished or was interrupted."
    # Release the lock file by closing the file descriptor
    exec 9>&-
    log "DEBUG" "Lock file '$LOCK_FILE' released."
}
trap cleanup_remove_script EXIT INT TERM # Ensure lock release and cleanup on exit/interrupt

# --- Helper Function: Get Free Disk Space ---
# Returns free disk space in Gibibytes (GB) for the filesystem of fullPath.
get_disk_free_gb() {
    local free_space_gb
    # df -BG: output in Gibibytes. --output=avail: show only available. tail -1: skip header. tr: remove non-digits.
    free_space_gb=$(df -BG --output=avail "$fullPath" 2>/dev/null | tail -n 1 | tr -dc '0-9')
    if [ -z "$free_space_gb" ]; then
        log "WARNING" "Could not determine free disk space for '$fullPath'. Assuming 0 GB free for safety in 'space' mode."
        echo "0" # Default to 0 if df fails, to be conservative in space checks
    else
        echo "$free_space_gb"
    fi
}

# --- Main Process Start ---
init_log "Old Backups/Logs Remover" # Initialize logging for this script

log "INFO" "Starting removal of old archive/log files in '$fullPath'."
log "INFO" "Cleanup Mode: '$CLEANUP_MODE'. Retention: '$BACKUP_RETAIN_DURATION' days. Disk Min Free: '$DISK_MIN_FREE_GB' GB (Enabled: $DISK_FREE_ENABLE)."
update_status "STARTED" "Removal of old backups/logs in '$fullPath'"

# Build the part of the find command for matching archive extensions.
# Results in: -iname '*.zip' -o -iname '*.tar' -o ...
archive_find_pattern_parts=""
for ext_item in "${ARCHIVE_EXTS[@]}"; do
    archive_find_pattern_parts+="-o -iname \"*.$ext_item\" "
done
archive_find_pattern_parts="${archive_find_pattern_parts:3}" # Remove leading " -o "

# Construct find commands. Using eval later to handle the dynamic pattern.
# For archives: find files older than BACKUP_RETAIN_DURATION days.
FIND_CMD_ARCHIVES="find \"$fullPath\" -type f \( $archive_find_pattern_parts \) -mtime +$BACKUP_RETAIN_DURATION"
# For logs: find .log files older than BACKUP_RETAIN_DURATION AND larger than MAX_LOG_SIZE.
FIND_CMD_LOGS="find \"$fullPath\" -type f -iname '*.log' -mtime +$BACKUP_RETAIN_DURATION -size +${MAX_LOG_SIZE}c"


total_archives_deleted_count=0
total_logs_deleted_count=0
total_archives_size_freed=0
total_logs_size_freed=0
candidate_archives_list=() # Array to store archive file paths found by find
candidate_logs_list=()   # Array to store log file paths found by find

# --- Core Deletion Logic Function ---
# Decides if a file should be deleted based on the selected CLEANUP_MODE.
# Args: $1 (file_path)
# Returns: 0 if file should be deleted, 1 otherwise.
should_delete_file() {
    local current_file_path="$1"
    local current_file_age_days
    local current_disk_free_gb

    case "$CLEANUP_MODE" in
        "time")
            # For 'time' mode, the find command already filtered by age.
            # So, any file passed here (if from that find) meets the age criteria.
            log "DEBUG" "Mode 'time': File '$current_file_path' is old enough (selected by find)."
            return 0 # Delete based on age
            ;;
        "space")
            # For 'space' mode, delete oldest files until DISK_MIN_FREE_GB is met.
            # Age is not a primary filter here, only order of deletion.
            if [ "$DISK_FREE_ENABLE" != "y" ]; then return 1; fi # Only act if disk free check is enabled
            current_disk_free_gb=$(get_disk_free_gb)
            if (( current_disk_free_gb < DISK_MIN_FREE_GB )); then
                log "DEBUG" "Mode 'space': Disk free ($current_disk_free_gb GB) < min ($DISK_MIN_FREE_GB GB). File '$current_file_path' candidate for deletion."
                return 0 # Delete to free space
            else
                log "DEBUG" "Mode 'space': Disk free ($current_disk_free_gb GB) >= min ($DISK_MIN_FREE_GB GB). Stopping deletions for now."
                return 1 # Enough space, stop deleting
            fi
            ;;
        "both")
            # For 'both' mode, file must be older than retention AND disk space must be below threshold.
            if [ "$DISK_FREE_ENABLE" != "y" ]; then return 1; fi # Only act if disk free check is enabled
            current_file_age_days=$(( ( $(date +%s) - $(stat -c %Y "$current_file_path" 2>/dev/null || echo 0) ) / 86400 ))
            if (( current_file_age_days >= BACKUP_RETAIN_DURATION )); then
                current_disk_free_gb=$(get_disk_free_gb)
                if (( current_disk_free_gb < DISK_MIN_FREE_GB )); then
                    log "DEBUG" "Mode 'both': File '$current_file_path' is old enough AND disk free ($current_disk_free_gb GB) < min ($DISK_MIN_FREE_GB GB)."
                    return 0 # Old enough AND need space
                else
                    log "DEBUG" "Mode 'both': File '$current_file_path' is old, but disk free ($current_disk_free_gb GB) >= min ($DISK_MIN_FREE_GB GB). Keeping."
                    return 1 # Old but enough space
                fi
            else
                log "DEBUG" "Mode 'both': File '$current_file_path' is not old enough ($current_file_age_days days). Keeping."
                return 1 # Not old enough
            fi
            ;;
        *) # Unknown mode
            log "WARNING" "Unknown CLEANUP_MODE: '$CLEANUP_MODE'. No files will be deleted by should_delete_file."
            return 1
            ;;
    esac
    return 1 # Default: do not delete
}

# --- Function to Process and Remove Files ---
# Iterates a list of files, checks deletion criteria, and removes them.
# Args: Files array passed by expansion ("${array[@]}")
# Output (via echo for read): count_deleted total_size_deleted
remove_files_based_on_criteria() {
    local files_to_process_array=("${@}") # Capture all arguments into an array
    local deleted_count_for_type=0
    local total_size_freed_for_type=0
    local current_file_to_remove
    local file_size_bytes

    # For 'space' or 'both' (when space matters), sort files by modification time (oldest first)
    # to ensure oldest are removed first when trying to meet space criteria.
    if [[ "$CLEANUP_MODE" == "space" ]] || [[ "$CLEANUP_MODE" == "both" && "$DISK_FREE_ENABLE" == "y" ]]; then
        log "INFO" "Sorting files by age (oldest first) for '$CLEANUP_MODE' mode."
        # Create a temporary array of "timestamp filepath" then sort, then extract filepath
        local temp_sortable_array=()
        for f_path in "${files_to_process_array[@]}"; do
            if [ -f "$f_path" ]; then # Ensure file exists before stat
                temp_sortable_array+=("$(stat -c "%Y %n" "$f_path" 2>/dev/null)")
            fi
        done
        # Sort numerically on first field (timestamp), then map back to file paths
        # Ensure IFS handles newlines correctly when reading from sorted list.
        # Using process substitution with `mapfile` (or `readarray`) is safer for filenames with spaces.
        mapfile -t files_to_process_array < <(printf '%s\n' "${temp_sortable_array[@]}" | sort -n -k1,1 | awk '{$1=""; print $0}' | sed 's/^ //')
    fi

    for current_file_to_remove in "${files_to_process_array[@]}"; do
        if [ ! -f "$current_file_to_remove" ]; then # File might have been deleted by another process or previous step
            log "DEBUG" "File '$current_file_to_remove' not found during processing loop. Skipping."
            continue
        fi

        if should_delete_file "$current_file_to_remove"; then
            file_size_bytes=$(stat -c %s "$current_file_to_remove" 2>/dev/null)
            [ -z "$file_size_bytes" ] && file_size_bytes=0 # Default to 0 if stat fails

            if [ "$DRY_RUN" = false ]; then
                log "INFO" "Removing '$current_file_to_remove' (Size: $(human_readable_size "$file_size_bytes")). Mode: '$CLEANUP_MODE'."
                if ! $QUIET; then echo -e "${RED}Removing: $current_file_to_remove ($(human_readable_size "$file_size_bytes"))${NC}"; fi
                rm -f -- "$current_file_to_remove" # -- to handle filenames starting with -
                if [ $? -ne 0 ]; then
                    log "ERROR" "Failed to remove file '$current_file_to_remove'."
                    continue # Skip to next file if removal failed
                fi
            else
                log "INFO" "[Dry Run] Would remove '$current_file_to_remove' (Size: $(human_readable_size "$file_size_bytes")). Mode: '$CLEANUP_MODE'."
                if ! $QUIET; then echo -e "${YELLOW}[Dry Run] Would remove: $current_file_to_remove ($(human_readable_size "$file_size_bytes"))${NC}"; fi
            fi
            deleted_count_for_type=$((deleted_count_for_type + 1))
            total_size_freed_for_type=$((total_size_freed_for_type + file_size_bytes))

            # For 'space' mode, re-check disk space after each deletion and stop if target met.
            # For 'both' mode, this check is inside should_delete_file for each file.
            if [[ "$CLEANUP_MODE" == "space" && "$DISK_FREE_ENABLE" == "y" ]]; then
                local current_disk_free_gb_after_del
                current_disk_free_gb_after_del=$(get_disk_free_gb)
                if (( current_disk_free_gb_after_del >= DISK_MIN_FREE_GB )); then
                    log "INFO" "Target disk free space ($DISK_MIN_FREE_GB GB) reached. Stopping further deletions in 'space' mode."
                    break # Stop deleting more files for this type
                fi
            fi
        fi
    done
    # Output counts for this type of file (archives or logs)
    echo "$deleted_count_for_type $total_size_freed_for_type"
}

# --- Record disk free space before any cleanup ---
DISK_SPACE_BEFORE_GB=$(get_disk_free_gb)
log "INFO" "Disk space before cleanup: ${DISK_SPACE_BEFORE_GB} GB."

# --- Process Archive Files ---
# Populate candidate_archives_list using the FIND_CMD_ARCHIVES
# Need to handle filenames with spaces correctly when reading from find.
# Using process substitution and mapfile (bash v4+) or a while read loop.
mapfile -t candidate_archives_list < <(eval "$FIND_CMD_ARCHIVES" 2>/dev/null)

if [ "${#candidate_archives_list[@]}" -gt 0 ]; then
    log "INFO" "Found ${#candidate_archives_list[@]} archive files older than $BACKUP_RETAIN_DURATION days (initial candidates)."
    # `read var1 var2 < <(command)` is a way to capture multiple outputs from a function/command.
    read -r total_archives_deleted_count total_archives_size_freed < <(remove_files_based_on_criteria "${candidate_archives_list[@]}")
    log "INFO" "Processed archive files. Deleted: $total_archives_deleted_count, Size Freed: $(human_readable_size "$total_archives_size_freed")."
else
    log "INFO" "No archive files found older than $BACKUP_RETAIN_DURATION days."
fi

# --- Process Log Files ---
# Populate candidate_logs_list (only if CLEANUP_MODE is 'time' or 'both' as age is a factor for logs)
# For 'space' only mode, log files typically aren't the primary target unless explicitly included or they are very old.
# The current FIND_CMD_LOGS includes age. If space mode should ignore age for logs, FIND_CMD_LOGS needs adjustment.
# Assuming current logic: logs are only deleted if old AND large.
if [[ "$CLEANUP_MODE" == "time" || "$CLEANUP_MODE" == "both" ]]; then
    mapfile -t candidate_logs_list < <(eval "$FIND_CMD_LOGS" 2>/dev/null)
    if [ "${#candidate_logs_list[@]}" -gt 0 ]; then
        log "INFO" "Found ${#candidate_logs_list[@]} log files older than $BACKUP_RETAIN_DURATION days AND larger than $(human_readable_size "$MAX_LOG_SIZE") (initial candidates)."
        read -r total_logs_deleted_count total_logs_size_freed < <(remove_files_based_on_criteria "${candidate_logs_list[@]}")
        log "INFO" "Processed log files. Deleted: $total_logs_deleted_count, Size Freed: $(human_readable_size "$total_logs_size_freed")."
    else
        log "INFO" "No large, old log files found matching criteria."
    fi
else
    log "INFO" "Log file cleanup skipped for CLEANUP_MODE='$CLEANUP_MODE' (criteria: age + size)."
fi


# --- Record disk free space after cleanup ---
DISK_SPACE_AFTER_GB=$(get_disk_free_gb)
log "INFO" "Disk space after cleanup: ${DISK_SPACE_AFTER_GB} GB."

# --- Create Summary and Send Notification ---
SUMMARY_TEMP_FILE=$(mktemp) # Create a temporary file for the summary
echo "Backup & Log Cleanup Summary" > "$SUMMARY_TEMP_FILE"
echo "============================" >> "$SUMMARY_TEMP_FILE"
echo "Date: $(date)" >> "$SUMMARY_TEMP_FILE"
echo "Host: $(hostname)" >> "$SUMMARY_TEMP_FILE"
echo "Target Path: $fullPath" >> "$SUMMARY_TEMP_FILE"
echo "Retention Period (for 'time'/'both' modes): $BACKUP_RETAIN_DURATION days" >> "$SUMMARY_TEMP_FILE"
echo "Cleanup Mode Selected: $CLEANUP_MODE" >> "$SUMMARY_TEMP_FILE"
if [ "$DISK_FREE_ENABLE" == "y" ]; then
    echo "Minimum Disk Free Target (if applicable): $DISK_MIN_FREE_GB GB" >> "$SUMMARY_TEMP_FILE"
else
    echo "Disk Free Space Target: Disabled" >> "$SUMMARY_TEMP_FILE"
fi
echo "" >> "$SUMMARY_TEMP_FILE"
echo "Archives Removed: $total_archives_deleted_count" >> "$SUMMARY_TEMP_FILE"
echo "Size Freed from Archives: $(human_readable_size "$total_archives_size_freed")" >> "$SUMMARY_TEMP_FILE"
echo "Log Files Removed: $total_logs_deleted_count" >> "$SUMMARY_TEMP_FILE"
echo "Size Freed from Logs: $(human_readable_size "$total_logs_size_freed")" >> "$SUMMARY_TEMP_FILE"
local total_size_freed_combined=$((total_archives_size_freed + total_logs_size_freed))
echo "Total Size Freed: $(human_readable_size "$total_size_freed_combined")" >> "$SUMMARY_TEMP_FILE"
echo "" >> "$SUMMARY_TEMP_FILE"
echo "Disk Free Before Cleanup: ${DISK_SPACE_BEFORE_GB} GB" >> "$SUMMARY_TEMP_FILE"
echo "Disk Free After Cleanup:  ${DISK_SPACE_AFTER_GB} GB" >> "$SUMMARY_TEMP_FILE"

# Send notification
local notify_status_type="INFO"
local notify_message_prefix=""
if [ "$DRY_RUN" = true ]; then
    notify_message_prefix="[Dry Run] "
    notify_status_type="INFO" # Dry runs are informational
else
    if [ "$total_archives_deleted_count" -gt 0 ] || [ "$total_logs_deleted_count" -gt 0 ]; then
        notify_status_type="SUCCESS" # Successful cleanup action
    fi # Else remains INFO if nothing was deleted
fi

notify "$notify_status_type" \
       "${notify_message_prefix}Removed $total_archives_deleted_count archives and $total_logs_deleted_count logs from '$fullPath'. Freed $(human_readable_size "$total_size_freed_combined"). Mode: $CLEANUP_MODE." \
       "Backup Cleanup Report" \
       "$SUMMARY_TEMP_FILE"


# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME)) # START_TIME from common.sh
FORMATTED_DURATION=$(format_duration "$DURATION") # format_duration from common.sh

log "INFO" "Old files removal process for '$fullPath' completed in ${FORMATTED_DURATION}."
update_status "SUCCESS" "Removed $total_archives_deleted_count archives, $total_logs_deleted_count logs from '$fullPath'. Freed $(human_readable_size "$total_size_freed_combined"). Duration: ${FORMATTED_DURATION}."

# Output summary to console if not in quiet mode
if ! $QUIET; then
    echo -e "\n${GREEN}${BOLD}--- Backup & Log Cleanup Summary ---${NC}"
    cat "$SUMMARY_TEMP_FILE" | sed -e "s/^/  ${GREEN}/${NC}" -e "s/=/=/g" # Indent and colorize
    echo -e "${GREEN}Time taken: ${NC}${BOLD}${FORMATTED_DURATION}${NC}"
fi

rm -f "$SUMMARY_TEMP_FILE" # Clean up the temporary summary file
# Lock is released by `trap cleanup_remove_script EXIT`

exit 0