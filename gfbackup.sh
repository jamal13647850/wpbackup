#!/bin/bash
#
# Script: gfbackup.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Backs up Gravity Forms data from a WordPress installation and uploads it remotely.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/gfbackup.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/gfbackup_status.log}"

# --- Default values for options ---
DRY_RUN=false
VERBOSE=false
# Note: QUIET and NAME_SUFFIX are not CLI options in this script version
# Note: BACKUP_LOCATION defaults to remote-only for this script logic

# Parse command line options
while getopts "c:f:dv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";; # Override compression format
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?) 
            echo "Usage: $0 -c <config_file> [-f <format>] [-d] [-v]" >&2
            exit 1
            ;;
    esac
done

# --- Configuration file processing ---
if [ -z "$CONFIG_FILE" ]; then
    log "ERROR" "Config file not specified! Use -c <config_file>"
    # No select_config_file call, requires -c to be passed.
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR" "Config file '$CONFIG_FILE' not found!"
    exit 1
else
    # Source the configuration file directly
    # Ensure config file variables do not overwrite critical script variables unintentionally.
    # common.sh's process_config_file is safer if complex config loading is needed.
    # For this script, direct sourcing is kept as per original.
    . "$CONFIG_FILE"
    log "INFO" "Successfully loaded configuration file: $CONFIG_FILE"
fi

# Check required variables from the sourced config file
# These are essential for Gravity Forms backup and remote upload.
REQUIRED_VARS_GF=("wpPath" "destinationPort" "destinationUser" "destinationIP" "destinationDbBackupPath" "privateKeyPath")
for var_name in "${REQUIRED_VARS_GF[@]}"; do
    if [ -z "${!var_name}" ]; then # Indirect variable expansion
        log "ERROR" "Required variable '$var_name' is not set in '$CONFIG_FILE'."
        exit 1
    fi
done

# Set default values if not specified in config (some might be in common.sh as well)
# DIR is set in common.sh
BACKUP_DIR_STAGING="${BACKUP_DIR_STAGING:-$SCRIPTPATH/backups}" # Staging area for backup files
DEST_TEMP="$BACKUP_DIR_STAGING/$DIR"                   # Temporary directory for this specific backup instance
FORM_FILE_PREFIX="${FORM_FILE_PREFIX:-GravityForms}"   # Prefix for the backup filename
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT_GF:-zip}}" # CLI > Config (COMPRESSION_FORMAT_GF) > Default (zip)
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"                        # Set by common.sh based on -v
LOG_LEVEL="${LOG_LEVEL:-normal}"                       # Default if not verbose
FORM_FILENAME="${FORM_FILE_PREFIX}-${DIR}.${COMPRESSION_FORMAT}" # Final backup filename

# --- Local SSH Validation Function ---
# This function is defined locally in this script.
# common.sh also has a validate_ssh function; this one will take precedence if called directly.
validate_ssh_local() {
    log "INFO" "Validating SSH connection to $destinationUser@$destinationIP:$destinationPort (using local function)..."
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo 'SSH Connection Test OK'" >/dev/null 2>&1
    # Using common.sh's check_status for consistency in error handling and logging
    check_status $? "SSH connection validation (local function)" "Forms Backup"
}

# --- Cleanup Function for Trap ---
# Ensures temporary directory ($DEST_TEMP) is removed on script exit or interruption.
cleanup_forms() {
    # Call common cleanup if needed, then script-specific cleanup
    cleanup "Forms backup process (invoked by trap)" "Forms Backup Cleanup" # General cleanup from common.sh
    log "INFO" "Gravity Forms backup process ended. Cleaning up specific temporary directory: $DEST_TEMP ..."
    if [ -d "$DEST_TEMP" ]; then
        rm -rf "$DEST_TEMP"
        log "INFO" "Temporary directory $DEST_TEMP removed."
    fi
}
trap cleanup_forms EXIT INT TERM # Use EXIT for more robust cleanup

# --- Main Backup Process Start ---
init_log "Gravity Forms Backup" # Initialize logging for this script

log "INFO" "Starting Gravity Forms backup process for instance: $DIR"
update_status "STARTED" "Gravity Forms backup process for ${wpHost:-$DIR}"

# Validate SSH connection (using the local version for this script)
validate_ssh_local # Call the local SSH validation function
log "INFO" "SSH connection validated successfully (using local function)."

# Create backup directories if not in dry run mode
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating directories: Staging='$BACKUP_DIR_STAGING', InstanceTemp='$DEST_TEMP'."
    mkdir -pv "$BACKUP_DIR_STAGING"
    check_status $? "Create main backup staging directory '$BACKUP_DIR_STAGING'" "Forms Backup"
    mkdir -pv "$DEST_TEMP"
    check_status $? "Create instance temporary directory '$DEST_TEMP'" "Forms Backup"
else
    log "INFO" "[Dry Run] Skipping directory creation."
fi

# --- Backup Gravity Forms Data ---
GF_BACKUP_SIZE_HR="N/A (Dry Run)"
if [ "$DRY_RUN" = false ]; then
    FORMS_DUMP_DIR="$DEST_TEMP/FormsDump" # Subdirectory for raw form JSON files
    mkdir -pv "$FORMS_DUMP_DIR"
    check_status $? "Create FormsDump subdirectory '$FORMS_DUMP_DIR'" "Forms Backup"
    
    cd "$FORMS_DUMP_DIR" || { log "ERROR" "Failed to change directory to $FORMS_DUMP_DIR. Aborting."; exit 1; }

    log "INFO" "Checking if Gravity Forms plugin is installed at '$wpPath'..."
    if wp_cli plugin is-installed gravityforms --path="$wpPath" >/dev/null 2>&1; then
        log "INFO" "Gravity Forms plugin is installed. Exporting all forms..."
        # Using wp_cli wrapper from common.sh
        # The --dir flag for `wp gf export` expects an existing directory.
        wp_cli gf export --path="$wpPath" --all --dir="$FORMS_DUMP_DIR"
        check_status $? "Exporting all Gravity Forms to '$FORMS_DUMP_DIR'" "Forms Backup"
        
        # Verify that some JSON files were created
        local exported_json_count
        exported_json_count=$(find "$FORMS_DUMP_DIR" -maxdepth 1 -name "*.json" -type f | wc -l)
        if [ "$exported_json_count" -eq 0 ]; then
            log "WARNING" "No JSON files found after Gravity Forms export. This might be normal if no forms exist, or it could indicate an issue."
            # Depending on requirements, this could be an error.
        else
            log "INFO" "Successfully exported $exported_json_count form(s) as JSON files."
        fi
    else
        log "ERROR" "Gravity Forms plugin is not installed or active at '$wpPath'. Cannot export forms."
        # notify "FAILURE" "Gravity Forms plugin not installed at '$wpPath'." "Forms Backup" # Using FAILURE status
        check_status 1 "Check Gravity Forms plugin installation" "Forms Backup" # Force failure
    fi
    
    cd "$DEST_TEMP" || { log "ERROR" "Failed to change directory back to $DEST_TEMP. Aborting."; exit 1; } # Go back to parent for compression

    log "DEBUG" "Starting forms data compression to '$FORM_FILENAME'."
    compress "$FORMS_DUMP_DIR" "$FORM_FILENAME" # Compress the FormsDump directory into $DEST_TEMP/$FORM_FILENAME
    check_status $? "Compress Gravity Forms data" "Forms Backup"
    
    log "INFO" "Cleaning up raw forms dump directory '$FORMS_DUMP_DIR'..."
    nice -n "$NICE_LEVEL" rm -rf "$FORMS_DUMP_DIR"
    check_status $? "Clean up raw FormsDump directory" "Forms Backup"
    
    # --- Create a Summary File for Attachment ---
    SUMMARY_FILE_PATH="$DEST_TEMP/forms_backup_summary.txt" # Corrected variable name
    log "INFO" "Creating backup summary file: $SUMMARY_FILE_PATH"
    echo "Gravity Forms Backup Summary" > "$SUMMARY_FILE_PATH"
    echo "=========================" >> "$SUMMARY_FILE_PATH"
    echo "Date: $(date)" >> "$SUMMARY_FILE_PATH"
    echo "Source Host: $(hostname)" >> "$SUMMARY_FILE_PATH"
    echo "WordPress Path: $wpPath" >> "$SUMMARY_FILE_PATH"
    echo "Backup Archive: $FORM_FILENAME" >> "$SUMMARY_FILE_PATH"
    if [ -f "$DEST_TEMP/$FORM_FILENAME" ]; then
        GF_BACKUP_SIZE_BYTES=$(du -b "$DEST_TEMP/$FORM_FILENAME" | cut -f1)
        GF_BACKUP_SIZE_HR=$(human_readable_size "$GF_BACKUP_SIZE_BYTES")
        echo "Backup Size: $GF_BACKUP_SIZE_HR" >> "$SUMMARY_FILE_PATH"
    else
        echo "Backup Size: Error - Archive not found" >> "$SUMMARY_FILE_PATH"
        GF_BACKUP_SIZE_HR="Error"
    fi
    echo "Forms Exported (JSON files): ${exported_json_count:-0}" >> "$SUMMARY_FILE_PATH" # Use count from earlier
    log "INFO" "Backup summary file created."

    # --- Upload to Remote Server ---
    # Destination path uses destinationDbBackupPath from config, assuming GF backups go with DB backups.
    log "INFO" "Uploading forms backup '$FORM_FILENAME' to remote server: $destinationUser@$destinationIP:$destinationDbBackupPath"
    nice -n "$NICE_LEVEL" rsync -az --info=progress2 --remove-source-files \
        -e "ssh -p \"${destinationPort:-22}\" -i \"${privateKeyPath}\"" \
        "$DEST_TEMP/$FORM_FILENAME" \
        "$destinationUser@$destinationIP:$destinationDbBackupPath/"
    check_status $? "Uploading forms backup and removing source" "Forms Backup"
    
    # Send notification with summary attachment
    # Ensure NOTIFY_ON_SUCCESS is handled (typically in common.sh or config)
    if [ "${NOTIFY_ON_SUCCESS:-true}" = true ]; then
        notify "SUCCESS" "Gravity Forms backup for ${wpHost:-$(basename "$wpPath")} completed. Archive: $FORM_FILENAME, Size: $GF_BACKUP_SIZE_HR." "Forms Backup" "$SUMMARY_FILE_PATH"
    fi
else
    log "INFO" "[Dry Run] Skipping Gravity Forms data backup, compression, and upload."
    if [ "${NOTIFY_ON_SUCCESS:-true}" = true ]; then # Notify even for dry run if enabled
        notify "INFO" "Dry run: Gravity Forms backup simulation for ${wpHost:-$(basename "$wpPath")} completed." "Forms Backup"
    fi
fi

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration "$DURATION")

log "INFO" "Gravity Forms backup process for instance $DIR completed successfully in ${FORMATTED_DURATION}."
update_status "SUCCESS" "Gravity Forms backup process for ${wpHost:-$DIR} completed in ${FORMATTED_DURATION}."

# Clean up summary file if it was created and not automatically removed by EXIT trap if DEST_TEMP is removed
# The EXIT trap should remove $DEST_TEMP which contains $SUMMARY_FILE_PATH
# If we want to be explicit:
# if [ "$DRY_RUN" = false ] && [ -f "$SUMMARY_FILE_PATH" ]; then
#     rm -f "$SUMMARY_FILE_PATH"
#     log "INFO" "Summary file $SUMMARY_FILE_PATH removed."
# fi

# The EXIT trap (cleanup_forms) will handle removal of $DEST_TEMP
exit 0