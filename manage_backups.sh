#!/bin/bash
#
# Script: manage_backups.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Manages local and remote WordPress backups with advanced features including
#              listing, selection, download, deletion, and full/partial restore orchestration.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific variables ---
LOG_FILE="$SCRIPTPATH/logs/manage_backups.log"
STAGING_RESTORE_DIR="$SCRIPTPATH/restore_staging_area_$$" # Unique staging dir using PID

CONFIG_FILE="" # Path to the currently loaded configuration file

# Variables to be populated from the selected config file
wpPath=""                      # WordPress installation path
LOCAL_BACKUP_DIR=""            # Path to local backups directory
DB_FILE_PREFIX="DB"            # Default prefix for database backup files
FILES_FILE_PREFIX="Files"      # Default prefix for files backup files
destinationUser=""             # SSH user for remote server
destinationIP=""               # SSH IP/hostname for remote server
destinationPort=""             # SSH port for remote server
privateKeyPath=""              # Path to SSH private key
destinationDbBackupPath=""     # Remote path for DB backups
destinationFilesBackupPath=""  # Remote path for Files backups

# QUIET flag default. This script does not currently have a CLI option to set it.
QUIET="${QUIET:-false}" # If QUIET is not set externally, defaults to false.

# Global array to hold listed backups for selection by ID
declare -a BKP_LIST_ARRAY
# Global associative array for details of a single selected backup (for manage actions)
declare -A SELECTED_BKP_DETAILS
# Global associative arrays for selections during the full restore process
declare -A SELECTED_DB_BKP_FOR_FULL_RESTORE
declare -A SELECTED_FILES_BKP_FOR_FULL_RESTORE


# --- Function to ensure a configuration file is loaded and validated ---
# Prompts for selection if CONFIG_FILE is not set.
# Returns: 0 on success, 1 on failure.
ensure_config_loaded() {
    if [ -z "$CONFIG_FILE" ]; then
        if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file loaded. Please select one.${NC}"; fi
        # select_config_file is from common.sh, sets CONFIG_FILE globally on success
        if ! select_config_file "$SCRIPTPATH/configs" "backup management"; then
            log "ERROR" "Configuration file selection failed or was cancelled."
            return 1
        fi
    fi

    # Process the configuration file (sources variables)
    # process_config_file is from common.sh
    if ! process_config_file "$CONFIG_FILE" "Backup Management"; then
        log "ERROR" "Failed to process configuration file '$CONFIG_FILE'."
        CONFIG_FILE="" # Reset to allow re-selection
        return 1
    fi

    # Validate essential variables that should be set by the config file
    local essential_vars=("wpPath" "LOCAL_BACKUP_DIR" "DB_FILE_PREFIX" "FILES_FILE_PREFIX")
    # If remote operations might be chosen, SSH details also become essential implicitly.
    # This check is for core local functionality. SSH details are checked later if remote is chosen.
    for var_name in "${essential_vars[@]}"; do
        if [ -z "${!var_name}" ]; then # Indirect variable expansion to check value
            log "ERROR" "Essential variable '$var_name' is not set in '$CONFIG_FILE'."
            if ! $QUIET; then
                echo -e "${RED}${BOLD}Error: Essential variable '$var_name' is not set in '$CONFIG_FILE'!${NC}" >&2
                echo -e "${YELLOW}Please ensure the configuration file is complete and correctly sourced.${NC}"
            fi
            CONFIG_FILE="" # Reset to force re-selection on next menu iteration
            return 1
        fi
    done
    log "INFO" "Configuration '$CONFIG_FILE' loaded and validated successfully."
    return 0
}

# --- Function to list backups from a source and allow user selection ---
# Args:
#   $1: source_type ("local" or "remote")
#   $2: filter_backup_type ("ALL", "DB", "FILES") - optional, defaults to "ALL"
#   $3: filter_date (YYYY-MM-DD) - optional, filters for backups on this specific date
#   $4: item_purpose ("manage", "select_db_for_full", "select_files_for_full") - determines which global array is populated
# Populates BKP_LIST_ARRAY and one of the SELECTED_*_DETAILS arrays based on item_purpose.
# Returns: 0 on successful selection, 1 on failure or quit.
list_and_select_backups() {
    local source_type="$1"                # "local" or "remote"
    local filter_bkp_type="${2:-ALL}"     # "ALL", "DB", or "FILES"
    local filter_date_str="${3:-}"        # YYYY-MM-DD string or empty
    local item_purpose="${4:-manage}"     # Purpose of selection, dictates which global array to fill

    local search_path_db_resolved=""
    local search_path_files_resolved="" # For remote, might be different for DB and Files
    local temp_file_listing # Temporary file for find/ssh output
    temp_file_listing=$(mktemp) # Create a secure temporary file

    BKP_LIST_ARRAY=() # Clear previous list
    # Clear the specific global array based on purpose
    case "$item_purpose" in
        "select_db_for_full") SELECTED_DB_BKP_FOR_FULL_RESTORE=() ;;
        "select_files_for_full") SELECTED_FILES_BKP_FOR_FULL_RESTORE=() ;;
        *) SELECTED_BKP_DETAILS=() ;; # Default to "manage"
    esac

    if ! $QUIET; then
        echo -e "${CYAN}Fetching list of ${source_type} backups...${NC}"
        [ "$filter_bkp_type" != "ALL" ] && echo -e "${CYAN}Filter Type: $filter_bkp_type${NC}"
        [ -n "$filter_date_str" ] && echo -e "${CYAN}Filter Date: $filter_date_str${NC}"
    fi

    # --- Construct find command filters ---
    local find_name_filter_db_part=""
    local find_name_filter_files_part=""
    if [ "$filter_bkp_type" = "ALL" ] || [ "$filter_bkp_type" = "DB" ]; then
        find_name_filter_db_part="-name \"${DB_FILE_PREFIX}*\""
    fi
    if [ "$filter_bkp_type" = "ALL" ] || [ "$filter_bkp_type" = "FILES" ]; then
        find_name_filter_files_part="-name \"${FILES_FILE_PREFIX}*\""
    fi

    local find_name_filter_combined_parts=""
    if [ -n "$find_name_filter_db_part" ] && [ -n "$find_name_filter_files_part" ]; then
        find_name_filter_combined_parts="\( $find_name_filter_db_part -o $find_name_filter_files_part \)"
    elif [ -n "$find_name_filter_db_part" ]; then
        find_name_filter_combined_parts="$find_name_filter_db_part"
    elif [ -n "$find_name_filter_files_part" ]; then
        find_name_filter_combined_parts="$find_name_filter_files_part"
    else
        log "ERROR" "No valid type filter for find command (DB or FILES prefix seems empty)."
        rm "$temp_file_listing"; return 1
    fi

    local find_date_filter_cmd_part=""
    if [ -n "$filter_date_str" ]; then
        # Validate date format (YYYY-MM-DD)
        if ! date -d "$filter_date_str" "+%Y-%m-%d" > /dev/null 2>&1; then
            log "ERROR" "Invalid date format: '$filter_date_str'. Please use YYYY-MM-DD."
            rm "$temp_file_listing"; return 1
        fi
        local day_after_filter_date_str
        day_after_filter_date_str=$(date -d "$filter_date_str + 1 day" "+%Y-%m-%d")
        # Find files modified on $filter_date_str (from 00:00:00 to 23:59:59)
        find_date_filter_cmd_part="-newermt \"$filter_date_str 00:00:00\" ! -newermt \"$day_after_filter_date_str 00:00:00\""
    fi
    
    # Base find command template with %PATH% placeholder
    # %TY-%Tm-%Td %TH:%TM: Modification date and time
    # %s: Size in bytes
    # %p: Full path
    local find_command_template="find %PATH% -maxdepth 1 -type f $find_name_filter_combined_parts $find_date_filter_cmd_part -printf \"%TY-%Tm-%Td %TH:%TM\\t%s\\t%p\\n\" 2>/dev/null"

    # --- Execute find command based on source_type ---
    if [ "$source_type" = "local" ]; then
        search_path_db_resolved="$LOCAL_BACKUP_DIR" # For local, DB and Files are in the same directory
        search_path_files_resolved="$LOCAL_BACKUP_DIR"
        local current_find_command_local="${find_command_template//%PATH%/$search_path_db_resolved}"
        log "DEBUG" "Local find command: $current_find_command_local"
        eval "$current_find_command_local" | sort -r > "$temp_file_listing" # Sort descending by date (first field)
    elif [ "$source_type" = "remote" ]; then
        # Ensure remote details are configured for remote listing
        for var_name in destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
            if [ -z "${!var_name}" ]; then
                log "ERROR" "Remote server detail '$var_name' not configured. Cannot list remote backups."
                rm "$temp_file_listing"; return 1
            fi
        done
        validate_ssh "$destinationUser" "$destinationIP" "${destinationPort:-22}" "$privateKeyPath" "Remote Backup Listing" || { rm "$temp_file_listing"; return 1; }

        search_path_db_resolved="$destinationDbBackupPath"
        search_path_files_resolved="$destinationFilesBackupPath"
        
        local remote_find_db_cmd_part="${find_command_template//%PATH%/$search_path_db_resolved}"
        local remote_find_files_cmd_part="${find_command_template//%PATH%/$search_path_files_resolved}"
        
        # Execute find for DB backups remotely if applicable
        if [ "$filter_bkp_type" = "ALL" ] || [ "$filter_bkp_type" = "DB" ]; then
            log "DEBUG" "Remote DB find command: $remote_find_db_cmd_part"
            ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "$remote_find_db_cmd_part" >> "$temp_file_listing"
        fi
        # Execute find for Files backups remotely if applicable (and paths differ or type is Files-only)
        if [ "$filter_bkp_type" = "ALL" ] || [ "$filter_bkp_type" = "FILES" ]; then
            # Avoid duplicate listing if DB and Files paths are the same and filter is ALL
            if ! ([ "$filter_bkp_type" = "ALL" ] && [ "$search_path_db_resolved" = "$search_path_files_resolved" ]); then
                 log "DEBUG" "Remote Files find command: $remote_find_files_cmd_part"
                 ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "$remote_find_files_cmd_part" >> "$temp_file_listing"
            fi
        fi
        # Sort the combined remote output
        sort -r -o "$temp_file_listing" "$temp_file_listing"
    else
        log "ERROR" "Invalid source type: '$source_type'."
        rm "$temp_file_listing"; return 1
    fi

    # --- Display listed backups and prompt for selection ---
    if [ ! -s "$temp_file_listing" ]; then # Check if temp file is empty
        if ! $QUIET; then echo -e "${YELLOW}No backups found matching your criteria for source: ${source_type}.${NC}"; fi
        log "INFO" "No backups found for source: $source_type with filters: Type=$filter_bkp_type, Date=$filter_date_str."
        rm "$temp_file_listing"; return 1
    fi

    if ! $QUIET; then
        echo -e "\n${BLUE}${BOLD}Available ${source_type} backups (sorted by date descending):${NC}"
        echo -e "------------------------------------------------------------------------------------"
        printf "%-4s %-20s %-12s %s\n" "ID" "Date Modified" "Size" "Filename (Type)"
        echo -e "------------------------------------------------------------------------------------"
    fi

    local idx=0
    while IFS=$'\t' read -r date_mod_str size_bytes_str full_path_str; do
        local filename_str backup_type_indicator_str human_size_str
        filename_str=$(basename "$full_path_str")
        human_size_str=$(human_readable_size "$size_bytes_str") # Using common.sh function

        if [[ "$filename_str" == "${DB_FILE_PREFIX}"* ]]; then
            backup_type_indicator_str="DB"
        elif [[ "$filename_str" == "${FILES_FILE_PREFIX}"* ]]; then
            backup_type_indicator_str="Files"
        else
            backup_type_indicator_str="Unknown"
        fi
        
        if ! $QUIET; then
            printf "%-4s %-20s %-12s %s (%s)\n" "$idx" "$date_mod_str" "$human_size_str" "$filename_str" "$backup_type_indicator_str"
        fi
        # Store details for potential selection
        BKP_LIST_ARRAY+=("$full_path_str|$filename_str|$backup_type_indicator_str|$source_type|$size_bytes_str")
        ((idx++))
    done < "$temp_file_listing"
    rm "$temp_file_listing" # Clean up temp file
    
    if ! $QUIET; then echo -e "------------------------------------------------------------------------------------"; fi

    if [ ${#BKP_LIST_ARRAY[@]} -eq 0 ]; then
         if ! $QUIET; then echo -e "${YELLOW}No backups processed from list (this should not happen if file had content).${NC}"; fi
        return 1
    fi

    local purpose_str_display="$item_purpose"
    if [ "$item_purpose" = "select_db_for_full" ]; then purpose_str_display="select DB backup for Full Restore"; fi
    if [ "$item_purpose" = "select_files_for_full" ]; then purpose_str_display="select Files backup for Full Restore"; fi

    local prompt_message="Enter ID of backup to $purpose_str_display (or 'q' to quit): "
    read -r -p "$prompt_message" selection_idx
    if [[ "$selection_idx" =~ ^[Qq]$ ]]; then log "INFO" "User quit selection."; return 1; fi

    # Validate selection_idx
    if ! [[ "$selection_idx" =~ ^[0-9]+$ ]] || [ "$selection_idx" -lt 0 ] || [ "$selection_idx" -ge ${#BKP_LIST_ARRAY[@]} ]; then
        log "ERROR" "Invalid selection ID: '$selection_idx'."
        if ! $QUIET; then echo -e "${RED}Invalid selection ID.${NC}"; fi
        return 1
    fi

    # Parse the selected backup's details from BKP_LIST_ARRAY
    IFS='|' read -r sel_full_path sel_filename sel_type_indicator sel_source_type sel_size_bytes <<< "${BKP_LIST_ARRAY[$selection_idx]}"
    
    # Use nameref to point to the correct global associative array based on item_purpose
    local -n target_assoc_array_ref
    case "$item_purpose" in
        "select_db_for_full")
            if [ "$sel_type_indicator" != "DB" ]; then
                log "ERROR" "Selection for DB full restore is not a DB backup type ('$sel_type_indicator')."
                if ! $QUIET; then echo -e "${RED}Selected item ($sel_filename) is not a DB backup.${NC}"; fi
                return 1;
            fi
            target_assoc_array_ref="SELECTED_DB_BKP_FOR_FULL_RESTORE"
            ;;
        "select_files_for_full")
            if [ "$sel_type_indicator" != "Files" ]; then
                log "ERROR" "Selection for Files full restore is not a Files backup type ('$sel_type_indicator')."
                if ! $QUIET; then echo -e "${RED}Selected item ($sel_filename) is not a Files backup.${NC}"; fi
                return 1;
            fi
            target_assoc_array_ref="SELECTED_FILES_BKP_FOR_FULL_RESTORE"
            ;;
        *) # Default to "manage"
            target_assoc_array_ref="SELECTED_BKP_DETAILS"
            ;;
    esac

    # Populate the target associative array
    target_assoc_array_ref=(
        [fullpath]="$sel_full_path"
        [filename]="$sel_filename"
        [type]="$sel_type_indicator"
        [source]="$sel_source_type"
        [size_bytes]="$sel_size_bytes"
    )
    log "INFO" "User selected backup ID $selection_idx for $item_purpose: $sel_filename (Type: $sel_type_indicator, Source: $sel_source_type)"
    return 0
}

# --- Function to download a selected remote backup ---
# Uses SELECTED_BKP_DETAILS global array.
download_selected_backup() {
    if [ -z "${SELECTED_BKP_DETAILS[filename]}" ] || [ "${SELECTED_BKP_DETAILS[source]}" != "remote" ]; then
        log "WARNING" "No remote backup selected or available for download."
        if ! $QUIET; then echo -e "${RED}No remote backup selected for download, or selected backup is not remote.${NC}"; fi
        return 1
    fi

    if ! $QUIET; then
        echo -e "\n${CYAN}Selected remote backup for download: ${BOLD}${SELECTED_BKP_DETAILS[filename]}${NC}"
    fi
    local default_download_target_dir="$LOCAL_BACKUP_DIR" # Default to the configured local backup dir
    mkdir -p "$default_download_target_dir" # Ensure it exists

    read -r -e -i "$default_download_target_dir" -p "Enter local directory to download to (default: $default_download_target_dir): " download_target_dir
    download_target_dir="${download_target_dir:-$default_download_target_dir}"

    if [ ! -d "$download_target_dir" ]; then
        read -r -p "Directory '$download_target_dir' does not exist. Create it? (y/N): " create_dir_confirm
        if [[ "$create_dir_confirm" =~ ^[Yy]$ ]]; then
            mkdir -p "$download_target_dir"
            if [ $? -ne 0 ]; then
                log "ERROR" "Failed to create download directory '$download_target_dir'."
                if ! $QUIET; then echo -e "${RED}Failed to create directory '$download_target_dir'. Download cancelled.${NC}"; fi
                return 1
            fi
        else
            log "INFO" "User cancelled download due to non-existent directory."
            if ! $QUIET; then echo -e "${YELLOW}Download cancelled.${NC}"; fi; return 1
        fi
    fi

    local local_target_file_path="$download_target_dir/${SELECTED_BKP_DETAILS[filename]}"
    if ! $QUIET; then echo -e "${CYAN}Downloading ${SELECTED_BKP_DETAILS[fullpath]} to $local_target_file_path...${NC}"; fi
    
    # Using rsync for download; scp could also be used. rsync provides progress.
    rsync -az --info=progress2 -e "ssh -p ${destinationPort:-22} -i \"${privateKeyPath}\"" \
        "$destinationUser@$destinationIP:\"${SELECTED_BKP_DETAILS[fullpath]}\"" \
        "$local_target_file_path" # Quote remote path in case of spaces (though unlikely from find)
    
    if [ $? -eq 0 ] && [ -f "$local_target_file_path" ]; then
        log "INFO" "Successfully downloaded remote backup '${SELECTED_BKP_DETAILS[filename]}' to '$local_target_file_path'."
        if ! $QUIET; then echo -e "${GREEN}Backup downloaded successfully to $local_target_file_path${NC}"; fi
    else
        log "ERROR" "Failed to download remote backup '${SELECTED_BKP_DETAILS[filename]}'."
        if ! $QUIET; then echo -e "${RED}Failed to download backup. Check logs and connection.${NC}"; fi
        return 1
    fi
    return 0
}


# --- Function to perform full restore using selected DB and Files backups ---
# Uses SELECTED_DB_BKP_FOR_FULL_RESTORE and SELECTED_FILES_BKP_FOR_FULL_RESTORE global arrays.
# Calls restore.sh script.
perform_full_restore() {
    if [ -z "${SELECTED_DB_BKP_FOR_FULL_RESTORE[filename]}" ] || [ -z "${SELECTED_FILES_BKP_FOR_FULL_RESTORE[filename]}" ]; then
        log "ERROR" "Full restore requires both a DB and a Files backup to be selected."
        if ! $QUIET; then echo -e "${RED}Both DB and Files backups must be selected for a full restore operation.${NC}"; fi
        return 1
    fi

    if ! $QUIET; then
        echo -e "\n${CYAN}${BOLD}--- Full Restore Confirmation ---${NC}"
        echo -e "  Database Backup: ${SELECTED_DB_BKP_FOR_FULL_RESTORE[filename]} (Source: ${SELECTED_DB_BKP_FOR_FULL_RESTORE[source]})"
        echo -e "  Files Backup:    ${SELECTED_FILES_BKP_FOR_FULL_RESTORE[filename]} (Source: ${SELECTED_FILES_BKP_FOR_FULL_RESTORE[source]})"
        echo -e "  Target Config:   $(basename "$CONFIG_FILE") (for WordPress path: $wpPath)"
        read -r -p "This will stage backups and invoke restore.sh for a FULL restore. Proceed? (y/N): " confirm_full_restore
        if [[ ! "$confirm_full_restore" =~ ^[Yy]$ ]]; then
            log "INFO" "User cancelled full restore operation."
            if ! $QUIET; then echo -e "${YELLOW}Full restore cancelled by user.${NC}"; fi
            return 1
        fi
    fi

    # Clean and create staging directory for restore process
    rm -rf "$STAGING_RESTORE_DIR" # Clean up any previous staging attempt
    mkdir -p "$STAGING_RESTORE_DIR"
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create staging directory for restore: $STAGING_RESTORE_DIR."
        if ! $QUIET; then echo -e "${RED}Failed to create staging directory: $STAGING_RESTORE_DIR${NC}"; fi
        return 1
    fi
    log "INFO" "Staging directory created: $STAGING_RESTORE_DIR"

    local staged_db_path="$STAGING_RESTORE_DIR/${SELECTED_DB_BKP_FOR_FULL_RESTORE[filename]}"
    local staged_files_path="$STAGING_RESTORE_DIR/${SELECTED_FILES_BKP_FOR_FULL_RESTORE[filename]}"

    # Stage DB backup (copy if local, scp if remote)
    log "INFO" "Staging DB backup '${SELECTED_DB_BKP_FOR_FULL_RESTORE[filename]}' to '$staged_db_path'."
    if ! $QUIET; then echo -e "${CYAN}Staging DB backup...${NC}"; fi
    if [ "${SELECTED_DB_BKP_FOR_FULL_RESTORE[source]}" = "local" ]; then
        cp "${SELECTED_DB_BKP_FOR_FULL_RESTORE[fullpath]}" "$staged_db_path"
    else # Remote
        scp -P "${destinationPort:-22}" -i "$privateKeyPath" \
            "$destinationUser@$destinationIP:\"${SELECTED_DB_BKP_FOR_FULL_RESTORE[fullpath]}\"" "$staged_db_path"
    fi
    if [ $? -ne 0 ] || [ ! -f "$staged_db_path" ]; then
        log "ERROR" "Failed to stage DB backup to '$staged_db_path'."
        if ! $QUIET; then echo -e "${RED}Failed to stage DB backup.${NC}"; fi
        rm -rf "$STAGING_RESTORE_DIR"; return 1
    fi

    # Stage Files backup
    log "INFO" "Staging Files backup '${SELECTED_FILES_BKP_FOR_FULL_RESTORE[filename]}' to '$staged_files_path'."
    if ! $QUIET; then echo -e "${CYAN}Staging Files backup...${NC}"; fi
    if [ "${SELECTED_FILES_BKP_FOR_FULL_RESTORE[source]}" = "local" ]; then
        cp "${SELECTED_FILES_BKP_FOR_FULL_RESTORE[fullpath]}" "$staged_files_path"
    else # Remote
        scp -P "${destinationPort:-22}" -i "$privateKeyPath" \
            "$destinationUser@$destinationIP:\"${SELECTED_FILES_BKP_FOR_FULL_RESTORE[fullpath]}\"" "$staged_files_path"
    fi
    if [ $? -ne 0 ] || [ ! -f "$staged_files_path" ]; then
        log "ERROR" "Failed to stage Files backup to '$staged_files_path'."
        if ! $QUIET; then echo -e "${RED}Failed to stage Files backup.${NC}"; fi
        rm -rf "$STAGING_RESTORE_DIR"; return 1
    fi

    log "INFO" "DB and Files backups staged successfully in '$STAGING_RESTORE_DIR'."
    if ! $QUIET; then echo -e "${GREEN}Backups staged successfully.${NC}"; fi

    # Export paths for restore.sh to use. These will be picked up by restore.sh.
    export MGMT_DB_BKP_PATH="$staged_db_path"
    export MGMT_FILES_BKP_PATH="$staged_files_path"
    log "INFO" "Environment variables MGMT_DB_BKP_PATH and MGMT_FILES_BKP_PATH set for restore.sh."

    local restore_script_full_path="$SCRIPTPATH/restore.sh"
    if [ ! -x "$restore_script_full_path" ]; then
        log "ERROR" "restore.sh script not found or not executable at '$restore_script_full_path'."
        if ! $QUIET; then echo -e "${RED}Error: restore.sh script not found or not executable at $restore_script_full_path${NC}"; fi
        rm -rf "$STAGING_RESTORE_DIR"; unset MGMT_DB_BKP_PATH MGMT_FILES_BKP_PATH; return 1
    fi
    
    if ! $QUIET; then
        echo -e "\n${YELLOW}${BOLD}Warning:${NC} The restore script (restore.sh) will now be invoked for a FULL restore."
        echo -e "It will use the staged backups. Please follow its prompts carefully."
        read -r -p "Press Enter to proceed with restore.sh, or Ctrl+C to abort NOW..."
    fi
    
    # Invoke restore.sh: -c (config), -t "full" (type), -s "local" (source of staged backups)
    # restore.sh will use the exported ENV VARS for specific backup file paths.
    "$restore_script_full_path" -c "$CONFIG_FILE" -t "full" -s "local" 
    local restore_status=$?

    # Cleanup is handled by the EXIT trap for manage_backups.sh (cleanup_management),
    # which includes removing STAGING_RESTORE_DIR and unsetting env vars.
    log "INFO" "restore.sh process finished with status $restore_status."
    if ! $QUIET; then echo -e "\n${GREEN}Full restore process initiated via restore.sh. Check its output and logs for details.${NC}"; fi
    return $restore_status
}

# --- Function to restore a single selected backup (DB or Files) ---
# Uses SELECTED_BKP_DETAILS global array. Calls restore.sh.
restore_single_selected_backup() {
    if [ -z "${SELECTED_BKP_DETAILS[filename]}" ]; then
        log "WARNING" "No backup selected for single restore operation."
        if ! $QUIET; then echo -e "${RED}No backup selected for restore.${NC}"; fi
        return 1
    fi

    if ! $QUIET; then
        echo -e "\n${CYAN}Preparing to restore single backup: ${BOLD}${SELECTED_BKP_DETAILS[filename]}${NC}"
        echo -e "  Type: ${SELECTED_BKP_DETAILS[type]}, Source: ${SELECTED_BKP_DETAILS[source]}"
        echo -e "  Target Config: $(basename "$CONFIG_FILE") (for WordPress path: $wpPath)"
    fi
    
    local restore_script_full_path="$SCRIPTPATH/restore.sh"
    if [ ! -x "$restore_script_full_path" ]; then
        log "ERROR" "restore.sh script not found or not executable at '$restore_script_full_path'."
        if ! $QUIET; then echo -e "${RED}Error: restore.sh script not found or not executable at $restore_script_full_path${NC}"; fi
        return 1
    fi

    local restore_type_cli_flag=""
    if [ "${SELECTED_BKP_DETAILS[type]}" = "DB" ]; then
        restore_type_cli_flag="db"
    elif [ "${SELECTED_BKP_DETAILS[type]}" = "Files" ]; then
        restore_type_cli_flag="files"
    else
        log "ERROR" "Unknown backup type '${SELECTED_BKP_DETAILS[type]}' for selected backup. Cannot determine restore type."
        if ! $QUIET; then echo -e "${RED}Unknown backup type: ${SELECTED_BKP_DETAILS[type]}. Cannot determine restore type.${NC}"; fi
        return 1
    fi

    if ! $QUIET; then
        echo -e "\n${YELLOW}${BOLD}Warning:${NC} This will invoke restore.sh to restore only this ${SELECTED_BKP_DETAILS[type]} backup."
        read -r -p "Proceed with restoring this single '${SELECTED_BKP_DETAILS[type]}' backup? (y/N): " confirm_single_restore
        if [[ ! "$confirm_single_restore" =~ ^[Yy]$ ]]; then
            log "INFO" "User cancelled single restore operation."
            if ! $QUIET; then echo -e "${YELLOW}Restore cancelled by user.${NC}"; fi
            return 1
        fi
    fi
    
    # Ensure no staging ENV VARS are set if not doing a staged full restore
    unset MGMT_DB_BKP_PATH MGMT_FILES_BKP_PATH
    
    # Call restore.sh: -c (config), -b (specific backup file path), -s (source of that file), -t (type db/files)
    "$restore_script_full_path" -c "$CONFIG_FILE" -b "${SELECTED_BKP_DETAILS[fullpath]}" -s "${SELECTED_BKP_DETAILS[source]}" -t "$restore_type_cli_flag"
    local restore_status=$?
    log "INFO" "Single restore process for '${SELECTED_BKP_DETAILS[filename]}' initiated via restore.sh. Status: $restore_status."
    if ! $QUIET; then echo -e "\n${GREEN}Single restore process initiated. Check restore.sh output and logs.${NC}"; fi
    return $restore_status
}

# --- Function to delete a selected backup ---
# Uses SELECTED_BKP_DETAILS global array.
delete_selected_backup() {
    if [ -z "${SELECTED_BKP_DETAILS[filename]}" ]; then
        log "WARNING" "No backup selected for deletion."
        if ! $QUIET; then echo -e "${RED}No backup selected for deletion.${NC}"; fi
        return 1
    fi

    if ! $QUIET; then
        echo -e "\n${RED}${BOLD}--- Confirm Deletion ---${NC}"
        echo -e "You are about to permanently delete the following backup:"
        echo -e "  Filename: ${SELECTED_BKP_DETAILS[filename]}"
        echo -e "  Type:     ${SELECTED_BKP_DETAILS[type]}"
        echo -e "  Source:   ${SELECTED_BKP_DETAILS[source]}"
        echo -e "  Full Path: ${SELECTED_BKP_DETAILS[fullpath]}"
        read -r -p "Are you absolutely sure? This action CANNOT be undone. (Type 'yes' to confirm): " confirm_delete_str
        if [[ "$confirm_delete_str" != "yes" ]]; then
            log "INFO" "User cancelled deletion of backup '${SELECTED_BKP_DETAILS[filename]}'."
            if ! $QUIET; then echo -e "${YELLOW}Deletion cancelled by user.${NC}"; fi
            return 1
        fi
    fi

    log "INFO" "Attempting to delete backup: ${SELECTED_BKP_DETAILS[filename]} from ${SELECTED_BKP_DETAILS[source]}."
    if ! $QUIET; then echo -e "${CYAN}Deleting backup: ${SELECTED_BKP_DETAILS[filename]}...${NC}"; fi
    local delete_op_status=1 # Assume failure initially

    if [ "${SELECTED_BKP_DETAILS[source]}" = "local" ]; then
        if [ -f "${SELECTED_BKP_DETAILS[fullpath]}" ]; then
            rm -f "${SELECTED_BKP_DETAILS[fullpath]}" # -f to suppress errors if file somehow vanished
            delete_op_status=$?
        else
            log "ERROR" "Local backup file not found for deletion: ${SELECTED_BKP_DETAILS[fullpath]}."
            if ! $QUIET; then echo -e "${RED}Error: Local backup file not found: ${SELECTED_BKP_DETAILS[fullpath]}${NC}"; fi
        fi
    elif [ "${SELECTED_BKP_DETAILS[source]}" = "remote" ]; then
        # Attempt to remove the remote file via SSH
        ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "rm -f \"${SELECTED_BKP_DETAILS[fullpath]}\""
        local ssh_rm_status=$?
        # Verify deletion by checking if the file no longer exists
        if [ $ssh_rm_status -eq 0 ]; then
             if ! ssh -p "${destinationPort:-22}" -i "$privateKeyPath" "$destinationUser@$destinationIP" "[ -f \"${SELECTED_BKP_DETAILS[fullpath]}\" ]"; then
                delete_op_status=0 # File does not exist, so deletion was successful
            else
                log "WARNING" "Remote file still exists after 'rm' command for '${SELECTED_BKP_DETAILS[fullpath]}'. Deletion might have failed."
                if ! $QUIET; then echo -e "${YELLOW}Warning: Could not confirm remote file deletion. Please check manually.${NC}"; fi
            fi
        else
            log "ERROR" "SSH 'rm' command failed for remote file '${SELECTED_BKP_DETAILS[fullpath]}'. Status: $ssh_rm_status."
        fi
    else
        log "ERROR" "Unknown backup source type '${SELECTED_BKP_DETAILS[source]}' for deletion."
        if ! $QUIET; then echo -e "${RED}Unknown backup source: ${SELECTED_BKP_DETAILS[source]}${NC}"; fi
        return 1
    fi

    if [ $delete_op_status -eq 0 ]; then
        log "INFO" "Successfully deleted backup '${SELECTED_BKP_DETAILS[filename]}' (Path: ${SELECTED_BKP_DETAILS[fullpath]}) from ${SELECTED_BKP_DETAILS[source]}."
        if ! $QUIET; then echo -e "${GREEN}Backup '${SELECTED_BKP_DETAILS[filename]}' deleted successfully from ${SELECTED_BKP_DETAILS[source]}.${NC}"; fi
        # Clear selection details as the item is gone
        SELECTED_BKP_DETAILS=()
        BKP_LIST_ARRAY=() # Force re-listing on next view as list is now outdated
        return 0
    else
        log "ERROR" "Failed to delete backup '${SELECTED_BKP_DETAILS[filename]}' (Path: ${SELECTED_BKP_DETAILS[fullpath]}) from ${SELECTED_BKP_DETAILS[source]}. Status: $delete_op_status."
        if ! $QUIET; then echo -e "${RED}Failed to delete backup '${SELECTED_BKP_DETAILS[filename]}'. Check logs.${NC}"; fi
        return 1
    fi
}

# --- Function to show actions for a selected backup ---
# Uses SELECTED_BKP_DETAILS. This is a sub-menu.
show_backup_actions_menu() {
    if [ -z "${SELECTED_BKP_DETAILS[filename]}" ]; then
        log "DEBUG" "show_backup_actions_menu called without a selected backup."
        if ! $QUIET; then echo -e "${RED}No backup is currently selected.${NC}"; fi
        return
    fi

    while true; do
        if ! $QUIET; then
            echo -e "\n${BLUE}${BOLD}--- Actions for Backup: ${SELECTED_BKP_DETAILS[filename]} ---${NC}"
            echo -e "  Type: ${SELECTED_BKP_DETAILS[type]}, Source: ${SELECTED_BKP_DETAILS[source]}, Path: ${SELECTED_BKP_DETAILS[fullpath]}"
            echo -e "${PURPLE}Choose an action:${NC}"
            echo "  1. Restore this ${SELECTED_BKP_DETAILS[type]} backup"
            echo "  2. Delete this backup"
            if [ "${SELECTED_BKP_DETAILS[source]}" = "remote" ]; then
                echo "  3. Download this backup to local storage"
            fi
            echo "  0. Back to Backup List / Main Menu"
        fi
        read -r -p "Enter action choice: " action_choice_val

        case "$action_choice_val" in
            1) restore_single_selected_backup ;;
            2) 
                delete_selected_backup
                # If deletion was successful, SELECTED_BKP_DETAILS is cleared, so break from this menu.
                if [ -z "${SELECTED_BKP_DETAILS[filename]}" ]; then break; fi
                ;;
            3)  
                if [ "${SELECTED_BKP_DETAILS[source]}" = "remote" ]; then
                    download_selected_backup
                else
                    if ! $QUIET; then echo -e "${RED}Invalid option: 'Download' is only for remote backups.${NC}"; fi
                fi
                ;;
            0) break ;; # Exit this sub-menu
            *) 
                if ! $QUIET; then echo -e "${RED}Invalid option, please try again.${NC}"; fi
                ;;
        esac
        # Pause for user to see action result before re-displaying menu, unless returning
        if [[ "$action_choice_val" =~ ^[1-3]$ ]] && ! $QUIET; then
            read -r -p "Press Enter to continue with actions for this backup..."
        fi
    done
}

# --- Helper function to prompt for list filters (Type and Date) ---
# Returns: "FILTER_TYPE|FILTER_DATE_STR" via echo
prompt_for_list_filters() {
    local filter_type_result="ALL" # Default
    local filter_date_result=""    # Default

    if ! $QUIET; then
        read -r -p "Filter by backup type? (A)ll, (D)B, (F)iles [Default: A]: " type_filter_choice
        case "$type_filter_choice" in
            [Dd]) filter_type_result="DB" ;;
            [Ff]) filter_type_result="FILES" ;;
            [Aa]|"") filter_type_result="ALL" ;; # Default to ALL if empty or A
            *)    
                echo -e "${YELLOW}Invalid type choice '$type_filter_choice'. Defaulting to ALL types.${NC}"
                filter_type_result="ALL" ;;
        esac

        read -r -p "Enter date (YYYY-MM-DD) to filter by (or leave empty for all dates): " date_filter_input
        if [ -n "$date_filter_input" ]; then
            # Validate date format
            if date -d "$date_filter_input" "+%Y-%m-%d" > /dev/null 2>&1; then
                filter_date_result="$date_filter_input"
            else
                echo -e "${YELLOW}Warning: Invalid date format '$date_filter_input'. Ignoring date filter.${NC}"
                filter_date_result="" # Reset if invalid
            fi
        fi
    fi
    # Return values combined with a delimiter
    echo "$filter_type_result|$filter_date_result"
}

# --- Helper function to wrap source selection and then call list_and_select_backups ---
# Used in the Full Restore process to select DB and Files backups from any source.
# Args:
#   $1: original_purpose (e.g., "select_db_for_full", "select_files_for_full")
#   $2: backup_kind_filter ("DB" or "FILES") - to filter the list for this specific kind
#   $3: filter_date_for_this_kind (YYYY-MM-DD string or empty)
# Returns: status of list_and_select_backups.
_list_and_select_backups_any_source_wrapper() {
    local original_purpose_val="$1"
    local backup_kind_filter_val="$2"
    local filter_date_val="$3"

    local selected_source_val=""
    if ! $QUIET; then
        echo -e "\n${CYAN}--- Select Source for $backup_kind_filter_val Backup ---${NC}"
        echo "  1. Local Storage"
        echo "  2. Remote Server"
        read -r -p "Choose source for $backup_kind_filter_val backup (1-2, or 'q' to cancel): " source_choice_val
    else # For non-interactive/QUIET mode, how to choose source? Needs design or default.
         # Defaulting to local for QUIET mode to avoid hanging, or could be an error.
         log "WARNING" "_list_and_select_backups_any_source_wrapper called in QUIET mode. Defaulting to 'local' source."
         source_choice_val="1" 
    fi

    case "$source_choice_val" in
        1) selected_source_val="local" ;;
        2) selected_source_val="remote" ;;
        [Qq]) log "INFO" "User cancelled source selection for $backup_kind_filter_val."; return 1 ;;
        *)  
            log "ERROR" "Invalid source choice '$source_choice_val' for $backup_kind_filter_val."
            if ! $QUIET; then echo -e "${RED}Invalid source choice.${NC}"; fi
            return 1 ;;
    esac

    # If remote selected, check if remote details are configured
    if [ "$selected_source_val" = "remote" ]; then
        for var_name in destinationUser destinationIP privateKeyPath; do # Check essential SSH vars
            if [ -z "${!var_name}" ]; then
                log "ERROR" "Cannot list remote $backup_kind_filter_val backups: SSH detail '$var_name' not configured."
                if ! $QUIET; then echo -e "${YELLOW}Remote server details (user, IP, key) not configured. Cannot list remote backups.${NC}"; fi
                return 1
            fi
        done
        # Path check (destinationDbBackupPath or destinationFilesBackupPath) is implicitly handled by list_and_select_backups
    fi

    # Call the main list_and_select_backups function with the chosen source and fixed type
    list_and_select_backups "$selected_source_val" "$backup_kind_filter_val" "$filter_date_val" "$original_purpose_val"
    return $? # Propagate return status from list_and_select_backups
}

# --- Main Menu Function ---
main_menu() {
    while true; do
        # Ensure config is loaded at the start of each menu loop iteration
        if ! ensure_config_loaded; then
             log "ERROR" "Configuration error. Cannot proceed with Backup Manager menu."
             if ! $QUIET; then
                 echo -e "\n${RED}${BOLD}Configuration Error:${NC} Could not load or validate a configuration file."
                 read -r -p "Would you like to try selecting a different configuration file? (y/N): " retry_config_sel
                 if [[ "$retry_config_sel" =~ ^[Yy]$ ]]; then
                     CONFIG_FILE="" # Clear current config path to trigger selection
                     wpPath=""      # Clear a key var to ensure re-validation
                     continue       # Restart menu loop to re-trigger ensure_config_loaded
                 else
                     echo -e "${RED}Exiting due to configuration error.${NC}"
                     exit 1
                 fi
             else # In QUIET mode, if config fails, exit.
                 exit 1
             fi
        fi

        if ! $QUIET; then
            echo -e "\n${BLUE}${BOLD}=== WordPress Backup Manager (v2.1) ===${NC}" # Updated version
            echo -e "  Using Config: ${CYAN}${BOLD}$(basename "${CONFIG_FILE:-Not Selected}")${NC}"
            echo -e "  WordPress Path: ${CYAN}${wpPath:-N/A}${NC}"
            echo -e "${PURPLE}--- List & Manage Individual Backups ---${NC}"
            echo "  1. List & Select Local Backups"
            echo "  2. List & Select Remote Backups"
            echo -e "${PURPLE}--- Advanced Restore Operations ---${NC}"
            echo "  3. Perform Full Restore (select DB & Files backups from any source)"
            echo -e "${PURPLE}--- Configuration ---${NC}"
            echo "  4. Change/Reload Configuration File"
            echo "  0. Exit Backup Manager"
        fi
        read -r -p "Enter your choice: " main_choice

        # Clear previous single selection details before new top-level action
        SELECTED_BKP_DETAILS=()
        # Clear full restore selections unless specifically in that workflow part
        if [[ ! "$main_choice" =~ ^(3)$ ]]; then # Keep selections if choosing step 2 of full restore
            SELECTED_DB_BKP_FOR_FULL_RESTORE=()
            SELECTED_FILES_BKP_FOR_FULL_RESTORE=()
        fi


        case "$main_choice" in
            1) # List & Select Local Backups
                local local_filters_str local_filter_type_val local_filter_date_val
                local_filters_str=$(prompt_for_list_filters)
                local_filter_type_val="${local_filters_str%|*}"
                local_filter_date_val="${local_filters_str#*|}"
                if list_and_select_backups "local" "$local_filter_type_val" "$local_filter_date_val" "manage"; then
                    show_backup_actions_menu # Show actions for the selected local backup
                fi
                ;;
            2) # List & Select Remote Backups
                # Check if remote details are configured before attempting to list
                local remote_details_ok=true
                for var_name in destinationUser destinationIP privateKeyPath destinationDbBackupPath destinationFilesBackupPath; do
                     if [ -z "${!var_name}" ]; then remote_details_ok=false; break; fi
                done
                if ! $remote_details_ok ; then
                    log "WARNING" "Cannot list remote backups: Remote server details are not fully configured in '$CONFIG_FILE'."
                    if ! $QUIET; then echo -e "${YELLOW}Remote server details (user, IP, key, paths) not configured in '$CONFIG_FILE'.${NC}"; fi
                else
                    local remote_filters_str remote_filter_type_val remote_filter_date_val
                    remote_filters_str=$(prompt_for_list_filters)
                    remote_filter_type_val="${remote_filters_str%|*}"
                    remote_filter_date_val="${remote_filters_str#*|}"
                    if list_and_select_backups "remote" "$remote_filter_type_val" "$remote_filter_date_val" "manage"; then
                        show_backup_actions_menu # Show actions for the selected remote backup
                    fi
                fi
                ;;
            3) # Perform Full Restore
                if ! $QUIET; then echo -e "\n${PURPLE}${BOLD}--- Full Restore: Step 1 of 2: Select Database Backup ---${NC}"; fi
                # Prompt for DB backup filters
                local db_filters_full_restore db_filter_type_fr db_filter_date_fr
                if ! $QUIET; then echo -e "${CYAN}Specify filters for the Database backup list:${NC}"; fi
                db_filters_full_restore=$(prompt_for_list_filters)
                db_filter_type_fr="${db_filters_full_restore%|*}" # Not used directly by wrapper, but good for log
                db_filter_date_fr="${db_filters_full_restore#*|}"
                
                # Select DB backup
                if ! _list_and_select_backups_any_source_wrapper "select_db_for_full" "DB" "$db_filter_date_fr"; then
                    log "WARNING" "DB backup selection for full restore cancelled or failed."
                    if ! $QUIET; then echo -e "${YELLOW}DB backup selection cancelled or failed. Full restore aborted.${NC}"; fi
                    continue # Back to main menu
                fi
                
                if ! $QUIET; then echo -e "\n${PURPLE}${BOLD}--- Full Restore: Step 2 of 2: Select Files Backup ---${NC}"; fi
                # Prompt for Files backup filters
                local files_filters_full_restore files_filter_type_fr files_filter_date_fr
                if ! $QUIET; then echo -e "${CYAN}Specify filters for the Files backup list:${NC}"; fi
                files_filters_full_restore=$(prompt_for_list_filters)
                files_filter_type_fr="${files_filters_full_restore%|*}" # Not used directly by wrapper
                files_filter_date_fr="${files_filters_full_restore#*|}"

                # Select Files backup
                if ! _list_and_select_backups_any_source_wrapper "select_files_for_full" "FILES" "$files_filter_date_fr"; then
                     log "WARNING" "Files backup selection for full restore cancelled or failed."
                     if ! $QUIET; then echo -e "${YELLOW}Files backup selection cancelled or failed. Full restore aborted.${NC}"; fi
                     SELECTED_DB_BKP_FOR_FULL_RESTORE=() # Clear DB selection if files selection fails
                     continue # Back to main menu
                fi
                
                # Both selected, proceed to perform_full_restore
                perform_full_restore
                # Clear selections after attempting restore
                SELECTED_DB_BKP_FOR_FULL_RESTORE=() 
                SELECTED_FILES_BKP_FOR_FULL_RESTORE=()
                ;;
            4) # Change Configuration File
                CONFIG_FILE="" # Clear current config path
                wpPath=""      # Clear a key variable to force re-validation by ensure_config_loaded
                log "INFO" "Configuration file has been unset. It will be prompted on the next relevant action or menu display."
                if ! $QUIET; then echo -e "${CYAN}Current configuration cleared. You will be prompted to select a new one.${NC}"; fi
                ;;
            0) # Exit
                if ! $QUIET; then echo -e "${GREEN}Exiting WordPress Backup Manager. Goodbye!${NC}"; fi
                exit 0
                ;;
            *) # Invalid option
                if ! $QUIET; then echo -e "${RED}Invalid option '$main_choice', please try again.${NC}"; fi
                ;;
        esac
        # Pause for user unless changing config or exiting, or in quiet mode
        if [[ ! "$main_choice" =~ ^[04]$ ]] && ! $QUIET; then
             read -r -p "Press Enter to return to the Main Menu..."
        fi
    done
}

# --- Script Entry Point & Global Cleanup Trap ---
cleanup_management_script() {
    log "INFO" "Backup Management script is finishing or was interrupted."
    # Unset environment variables that might have been set for restore.sh
    unset MGMT_DB_BKP_PATH
    unset MGMT_FILES_BKP_PATH
    log "DEBUG" "Unset MGMT_DB_BKP_PATH and MGMT_FILES_BKP_PATH."

    # Clean up the staging directory if it exists and contains anything
    if [ -d "$STAGING_RESTORE_DIR" ]; then
        if [ -n "$(ls -A "$STAGING_RESTORE_DIR" 2>/dev/null)" ]; then # Check if directory is not empty
            log "INFO" "Cleaning up restore staging directory: $STAGING_RESTORE_DIR"
            rm -rf "$STAGING_RESTORE_DIR"
            log "INFO" "Staging directory $STAGING_RESTORE_DIR removed."
        else # Directory exists but is empty
            rm -d "$STAGING_RESTORE_DIR" 2>/dev/null # Try to remove empty dir
            log "DEBUG" "Staging directory $STAGING_RESTORE_DIR was empty or already removed."
        fi
    fi
    # Call common cleanup if it exists and is intended for global script exit
    # cleanup "Backup Management Script Global" "Exit/Interrupt"
}
trap cleanup_management_script EXIT INT TERM # Trap for main script exit/interrupts

init_log "Backup Management V2.1" # Initialize main log for this script
log "INFO" "WordPress Backup Management script (V2.1) started."
# Initial configuration load attempt is handled by main_menu's loop

main_menu # Start the main interactive menu

exit 0 # Should be reached if user chooses to exit from main_menu