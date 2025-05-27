#!/bin/bash
#
# Script: common.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Common functions and variables for backup and restore scripts.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games:/opt/bin:/snap/bin:$PATH"

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Absolute path to the script directory
START_TIME=$(date +%s) # Script execution start time
DIR=$(date +%Y%m%d-%H%M%S) # Current timestamp for directory/file naming

# --- Color Codes for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Log and Status Files ---
# These can be overridden by the calling script before sourcing common.sh
LOG_FILE="${LOG_FILE:-$SCRIPTPATH/logs/script.log}"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/status.log}"

# --- Logging Function ---
# Args:
#   $1: level (ERROR, WARNING, INFO, DEBUG)
#   $2: message
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Skip DEBUG messages if LOG_LEVEL is not verbose
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "verbose" ]; then
        return
    fi

    # Always write to the log file
    echo -e "${timestamp} - [$level] $message" >> "$LOG_FILE"

    # Conditional console output based on level
    case "$level" in
        "ERROR")
            echo -e "${timestamp} - ${RED}${BOLD}[$level]${NC} $message" >&2 # Errors to stderr
            ;;
        "WARNING")
            echo -e "${timestamp} - ${YELLOW}${BOLD}[$level]${NC} $message" >&2 # Warnings to stderr
            ;;
        "INFO")
            if [ "$LOG_LEVEL" = "verbose" ] || [ "${QUIET:-false}" = false ]; then # Show INFO if verbose or not quiet
                echo -e "${timestamp} - ${GREEN}[$level]${NC} $message"
            fi
            ;;
        "DEBUG")
            # DEBUG messages to console only shown if LOG_LEVEL is verbose
            if [ "$LOG_LEVEL" = "verbose" ]; then
                echo -e "${timestamp} - ${CYAN}[$level]${NC} $message"
            fi
            ;;
        *) # Default case for other levels
            echo -e "${timestamp} - [$level] $message"
            ;;
    esac
}

# --- Status Update Function ---
# Args:
#   $1: status (e.g., STARTED, SUCCESS, FAILED, INTERRUPTED)
#   $2: message
update_status() {
    local status="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "${timestamp} - [${status}] ${message}" >> "$STATUS_LOG"
}

# --- Command Status Check ---
# Exits script on failure.
# Args:
#   $1: status code of the last command ($?)
#   $2: operation description (string)
#   $3: process type (string, for notification context, e.g., "Backup", "Restore")
check_status() {
    local status=$1
    local operation="$2"
    local process_type="${3:-Script}" # Default process type if not provided

    if [ $status -ne 0 ]; then
        log "ERROR" "$operation failed with status $status"
        update_status "FAILURE" "$operation failed with status $status" # Changed from FAILED to FAILURE for consistency
        # Conditional notification to avoid flood if called within notify itself or if NOTIFY var is false.
        if [[ -z ${INSIDE_NOTIFY_LOCK:-} ]] && [[ "${NOTIFY:-true}" == true ]]; then
             export INSIDE_NOTIFY_LOCK=true # Simple lock to prevent recursive notifications
             notify "FAILURE" "$operation failed. Status: $status" "$process_type"
             unset INSIDE_NOTIFY_LOCK
        fi
        echo -e "${RED}${BOLD}Error:${NC} $operation failed with status $status. Check log for details: $LOG_FILE" >&2
        # Consider if exit is always desired here, or if the calling script should decide.
        # For now, keeping the original behavior.
        exit $status
    else
        log "DEBUG" "$operation completed successfully"
    fi
}

# --- Notification Function ---
# Sends notifications via configured methods.
# Args:
#   $1: status (e.g., SUCCESS, FAILURE)
#   $2: message
#   $3: process type (string, e.g., "Backup", "System Alert")
#   $4: attachment_path (optional)
notify() {
    local status="$1"
    local message="$2"
    local process_type="$3"
    local attachment_path="${4:-}"
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local full_message="[$status] $process_type Process on $hostname at $timestamp\n\n$message"

    if [ -z "$NOTIFY_METHOD" ] || [ "$NOTIFY_METHOD" = "none" ]; then
        log "DEBUG" "No notification method configured or set to 'none'. Skipping notifications."
        return
    fi

    log "DEBUG" "Preparing to send notifications via: $NOTIFY_METHOD"

    IFS=',' read -ra METHODS <<< "$NOTIFY_METHOD"
    for method in "${METHODS[@]}"; do
        case "$method" in
            "email")
                if [ -n "$NOTIFY_EMAIL" ]; then
                    log "DEBUG" "Sending email notification to $NOTIFY_EMAIL"
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then
                        echo -e "$full_message" | mail -s "[$status] $process_type on $hostname" -a "$attachment_path" "$NOTIFY_EMAIL"
                        log "INFO" "Email notification with attachment sent to $NOTIFY_EMAIL"
                    else
                        echo -e "$full_message" | mail -s "[$status] $process_type on $hostname" "$NOTIFY_EMAIL"
                        log "INFO" "Email notification sent to $NOTIFY_EMAIL"
                    fi
                else
                    log "WARNING" "Email notification method enabled, but NOTIFY_EMAIL is not set."
                fi
                ;;
            "slack")
                if [ -n "$SLACK_WEBHOOK_URL" ]; then
                    log "DEBUG" "Sending Slack notification."
                    # Simplified Slack message for broader compatibility, consider more complex JSON if needed
                    local slack_text_message="*[$status] $process_type Process on $hostname* ($timestamp)\n$message"
                    local slack_payload
                    slack_payload=$(printf '{"text": "%s"}' "$slack_text_message")
                    curl -s -X POST -H 'Content-type: application/json' --data "$slack_payload" "$SLACK_WEBHOOK_URL"
                    # Slack file upload typically requires specific channel ID and token handling
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ] && [ -n "$SLACK_API_TOKEN" ] && [ -n "$SLACK_CHANNEL" ]; then
                        log "DEBUG" "Uploading attachment '$attachment_path' to Slack channel '$SLACK_CHANNEL'."
                        curl -s -F file=@"$attachment_path" \
                             -F "initial_comment=[$status] $process_type: $message" \
                             -F channels="$SLACK_CHANNEL" \
                             -H "Authorization: Bearer $SLACK_API_TOKEN" \
                             https://slack.com/api/files.upload > /dev/null
                        log "INFO" "Slack attachment upload attempted."
                    elif [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then
                        log "WARNING" "Slack attachment specified, but SLACK_API_TOKEN or SLACK_CHANNEL is not set."
                    fi
                    log "INFO" "Slack notification sent."
                else
                    log "WARNING" "Slack notification method enabled, but SLACK_WEBHOOK_URL is not set."
                fi
                ;;
            "telegram")
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                    log "DEBUG" "Sending Telegram notification."
                    # Ensure message is properly formatted/escaped for MarkdownV2 if used
                    local telegram_text_message="*[$status] $process_type Process on $hostname*\n_$timestamp_\n\n$message"
                    # Basic escaping for MarkdownV2 (incomplete, but better than none)
                    telegram_text_message=$(echo "$telegram_text_message" | sed 's/\([_*\[\]()~`>#+-=|{}.!]\)/\\\1/g')
                    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                        -d chat_id="$TELEGRAM_CHAT_ID" \
                        -d text="$telegram_text_message" \
                        -d parse_mode="MarkdownV2" > /dev/null
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then
                        log "DEBUG" "Uploading attachment '$attachment_path' to Telegram."
                        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
                            -F chat_id="$TELEGRAM_CHAT_ID" \
                            -F document=@"$attachment_path" \
                            -F caption="[$status] $process_type: $message" > /dev/null
                        log "INFO" "Telegram attachment upload attempted."
                    fi
                    log "INFO" "Telegram notification sent."
                else
                    log "WARNING" "Telegram notification method enabled, but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is not set."
                fi
                ;;
            *)
                log "WARNING" "Unknown notification method: $method"
                ;;
        esac
    done
}

# --- Compression Function ---
# Compresses a source file or directory to an output archive.
# Args:
#   $1: source (file or directory path)
#   $2: output (archive file path, extension determines format)
compress() {
    local source_item="$1" # Renamed to avoid conflict with bash 'source'
    local output_file="$2" # Renamed for clarity
    local compression_cmd=""
    local nice_prefix="nice -n ${NICE_LEVEL:-19}" # Use default NICE_LEVEL if not set

    # Ensure source exists before attempting compression
    if [ ! -e "$source_item" ]; then
        log "ERROR" "Compression source '$source_item' not found."
        return 1
    fi

    case "${output_file##*.}" in # Get extension
        "zip")
            compression_cmd="$nice_prefix zip -qr \"$output_file\" \"$source_item\"" # -q for quiet
            ;;
        "gz")
            if [[ "$output_file" == *.tar.gz ]] || [[ "$output_file" == *.tgz ]]; then
                compression_cmd="$nice_prefix tar -czf \"$output_file\" -C \"$(dirname "$source_item")\" \"$(basename "$source_item")\""
            else # Simple gzip of a single file
                compression_cmd="$nice_prefix gzip -c \"$source_item\" > \"$output_file\""
            fi
            ;;
        "bz2")
            if [[ "$output_file" == *.tar.bz2 ]]; then
                compression_cmd="$nice_prefix tar -cjf \"$output_file\" -C \"$(dirname "$source_item")\" \"$(basename "$source_item")\""
            else # Simple bzip2 of a single file
                compression_cmd="$nice_prefix bzip2 -c \"$source_item\" > \"$output_file\""
            fi
            ;;
        "xz")
            if [[ "$output_file" == *.tar.xz ]]; then
                compression_cmd="$nice_prefix tar -cJf \"$output_file\" -C \"$(dirname "$source_item")\" \"$(basename "$source_item")\""
            else # Simple xz of a single file
                compression_cmd="$nice_prefix xz -c \"$source_item\" > \"$output_file\""
            fi
            ;;
        "tar") # Uncompressed tar
            compression_cmd="$nice_prefix tar -cf \"$output_file\" -C \"$(dirname "$source_item")\" \"$(basename "$source_item")\""
            ;;
        *)
            log "ERROR" "Unsupported compression format for '$output_file'."
            return 1
            ;;
    esac

    log "DEBUG" "Executing compression: $compression_cmd"
    eval "$compression_cmd" # eval is used to correctly handle quotes in paths and commands
    return $?
}

# --- Configuration File Selection Function ---
# Interactively prompts user to select a .conf or .conf.gpg file.
# Args:
#   $1: config_dir (directory to search for config files)
#   $2: script_type (string, e.g., "Backup", "Restore" - for context, not used in logic here)
# Sets CONFIG_FILE globally.
select_config_file() {
    local config_dir="$1"
    # local script_type="$2" # Not used in current logic but good for context
    local configs=()
    local i=0
    local file_path # Changed from 'file' to 'file_path' to avoid conflict with 'mail -a file'

    if [ ! -d "$config_dir" ]; then
        log "ERROR" "Config directory '$config_dir' not found!"
        return 1
    fi

    log "INFO" "Scanning for configuration files in '$config_dir'..."
    # Read unencrypted .conf files
    while IFS= read -r file_path; do
        configs+=("$file_path")
        echo -e "[$i] ${CYAN}$(basename "$file_path")${NC}"
        ((i++))
    done < <(find "$config_dir" -maxdepth 1 -type f -name "*.conf" ! -name "*.gpg" | sort) # Ensure only .conf, not .conf.gpg

    # Read encrypted .conf.gpg files
    while IFS= read -r file_path; do
        configs+=("$file_path")
        echo -e "[$i] ${PURPLE}$(basename "$file_path")${NC} (encrypted)"
        ((i++))
    done < <(find "$config_dir" -maxdepth 1 -type f -name "*.conf.gpg" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        log "ERROR" "No configuration files found in '$config_dir'."
        return 1
    fi

    echo -e "${GREEN}Select a configuration file by number:${NC}"
    read -r -p "> " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 0 ] || [ "$selection" -ge ${#configs[@]} ]; then
        log "ERROR" "Invalid selection: '$selection'."
        return 1
    fi

    CONFIG_FILE="${configs[$selection]}" # Sets the global CONFIG_FILE variable
    log "INFO" "User selected configuration file: $(basename "$CONFIG_FILE")"
    return 0
}

# --- Cleanup Function ---
# General cleanup operations. Kills background jobs.
# Args:
#   $1: process_name (string, name of the process being cleaned up)
#   $2: process_type (string, type of process for logging)
cleanup() {
    local process_name="$1"
    local process_type="$2" # Often the script name like "Backup" or "Restore"

    log "INFO" "$process_type ($process_name) interrupted or finished. Performing cleanup..."
    # update_status "INTERRUPTED" "$process_type process for $DIR" # DIR might not be relevant here or could be passed

    # Kill all background jobs spawned by this script/shell
    local job_pids
    job_pids=$(jobs -p)
    if [ -n "$job_pids" ]; then
        log "INFO" "Terminating background jobs: $job_pids"
        # Using xargs -r to avoid running kill if no jobs are present
        echo "$job_pids" | xargs -r kill -TERM 2>/dev/null
        sleep 1 # Give them a moment to terminate gracefully
        echo "$job_pids" | xargs -r kill -KILL 2>/dev/null # Force kill if still running
    else
        log "INFO" "No background jobs to terminate."
    fi
    return 0
}

# --- Configuration File Loading Function ---
# Outputs decrypted config content or cats unencrypted.
# Args:
#   $1: config_file path
# Returns: 1 on failure, 0 on success (implicitly by gpg/cat). Output is to STDOUT.
load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        # This function outputs commands to be eval'd, so its error messages must also be commands
        echo "echo -e \"${RED}${BOLD}Error: Configuration file '$config_file' not found!${NC}\" >&2; exit 1"
        return 1
    fi

    if [[ "$config_file" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            echo "echo -e \"${RED}${BOLD}Error: gpg is not installed but required for '$config_file'!${NC}\" >&2; exit 1"
            return 1
        fi
        # Decrypt to STDOUT. Errors from gpg (like bad passphrase) go to STDERR.
        gpg --quiet --decrypt "$config_file" 2>/dev/null
    else
        cat "$config_file"
    fi
    # The calling function should check gpg/cat's exit status if critical
}

# --- Command Existence Check ---
# Checks if a command is available in PATH.
# Args:
#   $1: command_name
# Returns: 0 if exists, 1 if not.
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- Required Commands Check ---
# Checks for a list of required commands.
# Args:
#   $@: list of command names
# Returns: 1 if any command is missing, 0 if all exist.
check_requirements() {
    local missing_commands=()
    local cmd

    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log "ERROR" "Required commands not found: ${missing_commands[*]}"
        echo -e "${RED}${BOLD}Error: Required commands not found: ${missing_commands[*]}${NC}" >&2
        echo -e "${YELLOW}Please install the missing command(s) and try again.${NC}" >&2
        return 1
    fi
    return 0
}

# --- Log File Initialization ---
# Creates log directory and adds a header to the log file.
# Args:
#   $1: script_name (string to identify the script in logs)
init_log() {
    local script_name="$1"
    # Create logs directory if it doesn't exist
    if ! mkdir -p "$SCRIPTPATH/logs"; then
        echo -e "${RED}${BOLD}Error: Could not create log directory at $SCRIPTPATH/logs. Check permissions.${NC}" >&2
        # exit 1 # Critical, cannot log
    fi
    # Check if LOG_FILE is writable
    if ! touch "$LOG_FILE" 2>/dev/null; then
         echo -e "${RED}${BOLD}Error: Log file $LOG_FILE is not writable. Check permissions.${NC}" >&2
         # exit 1 # Critical
    fi

    echo -e "\n----------------------------------------" >> "$LOG_FILE"
    echo -e "Starting $script_name at $(date)" >> "$LOG_FILE"
    echo -e "Script Path: $SCRIPTPATH" >> "$LOG_FILE"
    echo -e "Log File: $LOG_FILE" >> "$LOG_FILE"
    echo -e "----------------------------------------" >> "$LOG_FILE"
}

# --- Duration Formatting Function ---
# Converts seconds to a human-readable string (Xd Yh Zm As).
# Args:
#   $1: seconds (integer)
format_duration() {
    local seconds=$1
    local days=$((seconds / 86400))
    seconds=$((seconds % 86400))
    local hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    local duration_str=""

    if [ $days -gt 0 ]; then
        duration_str="${days}d "
    fi
    if [ $hours -gt 0 ] || [ -n "$duration_str" ]; then # Show hours if days are shown or hours > 0
        duration_str="${duration_str}${hours}h "
    fi
    if [ $minutes -gt 0 ] || [ -n "$duration_str" ]; then # Show minutes if hours/days are shown or minutes > 0
        duration_str="${duration_str}${minutes}m "
    fi
    duration_str="${duration_str}${remaining_seconds}s"

    echo "$duration_str" | sed 's/^ *//;s/ *$//' # Trim leading/trailing spaces
}

# --- Human-Readable Size Function ---
# Converts bytes to KB, MB, GB, TB.
# Args:
#   $1: size_in_bytes (integer)
human_readable_size() {
    local size_bytes=$1
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_idx=0
    local remainder=0

    # Use awk for floating point arithmetic for better precision
    echo "$size_bytes" | awk '{
        size = $1
        units = "B KB MB GB TB PB"
        split(units, u_arr, " ")
        unit_idx = 1
        while (size >= 1024 && unit_idx < length(u_arr)) {
            size /= 1024
            unit_idx++
        }
        printf "%.1f%s\n", size, u_arr[unit_idx]
    }'
}

# --- Configuration File Processing Function ---
# Sources a .conf file or decrypts and sources a .conf.gpg file.
# Args:
#   $1: config_file path
#   $2: script_type (string, for logging context)
process_config_file() {
    local config_file="$1"
    local script_type="$2" # For logging context

    if [ ! -f "$config_file" ]; then
        log "ERROR" "Configuration file '$config_file' not found for $script_type."
        echo -e "${RED}${BOLD}Error: Configuration file '$config_file' not found!${NC}" >&2
        exit 1 # Critical error
    fi

    if ! $QUIET; then echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$config_file")${NC}"; fi

    if [[ "$config_file" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            log "ERROR" "gpg command not found, required for encrypted config '$config_file'."
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            exit 1
        fi
        if ! $QUIET; then echo -e "${CYAN}Loading encrypted configuration file: $(basename "$config_file")${NC}"; fi
        # Decrypt and source in the current shell
        # Ensure GPG_TTY is set if using pinentry, or use --batch --passphrase-fd 0 for non-interactive
        # For simplicity, assuming decryption doesn't require complex TTY handling here.
        local decrypted_config
        decrypted_config=$(gpg --quiet --decrypt "$config_file" 2>/dev/null)
        local gpg_status=$?
        if [ $gpg_status -ne 0 ] || [ -z "$decrypted_config" ]; then
            log "ERROR" "Failed to decrypt or empty configuration file: '$config_file'. GPG status: $gpg_status"
            echo -e "${RED}${BOLD}Error: Failed to decrypt or empty configuration file! Check passphrase or file integrity.${NC}" >&2
            exit 1
        fi
        # Source the decrypted content
        eval "$decrypted_config"
        log "INFO" "Successfully loaded and sourced encrypted configuration: $(basename "$config_file") for $script_type"
    else
        # Source the plain text config file
        # shellcheck source=/dev/null
        . "$config_file"
        log "INFO" "Successfully loaded and sourced configuration: $(basename "$config_file") for $script_type"
    fi
}

# --- SSH Connection Validation Function ---
# Args:
#   $1: user
#   $2: ip
#   $3: port (defaults to 22 if empty/null)
#   $4: key_path
#   $5: process_type (for check_status context)
validate_ssh() {
    local ssh_user="$1"
    local ssh_ip="$2"
    local ssh_port="${3:-22}" # Default to port 22 if not provided
    local ssh_key_path="$4"
    local process_type="$5"

    if ! $QUIET; then echo -e "${CYAN}${BOLD}Validating SSH connection to $ssh_user@$ssh_ip:$ssh_port...${NC}"; fi
    # -o StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null can be risky but useful for automation.
    # For better security, ensure host keys are pre-accepted or manage known_hosts.
    # Adding ConnectTimeout to prevent indefinite hanging.
    ssh -o ConnectTimeout=10 -p "$ssh_port" -i "$ssh_key_path" "$ssh_user@$ssh_ip" "echo 'SSH connection successful'" >/dev/null 2>&1
    check_status $? "SSH connection validation ($ssh_user@$ssh_ip:$ssh_port)" "$process_type"
}

# --- Backup Archive Extraction Function ---
# Extracts various archive formats.
# Args:
#   $1: backup_file path
#   $2: extract_dir path
extract_backup() {
    local backup_file="$1"
    local extract_dir="$2"
    local nice_prefix="nice -n ${NICE_LEVEL:-19}"

    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file '$backup_file' not found for extraction."
        return 1
    fi

    if ! mkdir -p "$extract_dir"; then
        log "ERROR" "Failed to create extraction directory '$extract_dir'."
        return 1
    fi
    log "INFO" "Extracting '$backup_file' to '$extract_dir'..."

    case "${backup_file}" in # Match against full filename for more robust .tar.gz etc.
        *.tar.gz|*.tgz)
            $nice_prefix tar -xzf "$backup_file" -C "$extract_dir"
            ;;
        *.tar.bz2|*.tbz2)
            $nice_prefix tar -xjf "$backup_file" -C "$extract_dir"
            ;;
        *.tar.xz|*.txz)
            $nice_prefix tar -xJf "$backup_file" -C "$extract_dir"
            ;;
        *.zip)
            $nice_prefix unzip -o "$backup_file" -d "$extract_dir" # -o to overwrite without prompting
            ;;
        *.gz) # Single gzipped file (not tar.gz)
            $nice_prefix gunzip -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .gz)"
            ;;
        *.bz2) # Single bzipped2 file
            $nice_prefix bunzip2 -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .bz2)"
            ;;
        *.xz) # Single xz compressed file
            $nice_prefix unxz -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .xz)"
            ;;
        *.tar) # Uncompressed tar
            $nice_prefix tar -xf "$backup_file" -C "$extract_dir"
            ;;
        *)
            log "ERROR" "Unsupported archive format for extraction: '$backup_file'."
            return 1
            ;;
    esac
    local extract_status=$?
    if [ $extract_status -eq 0 ]; then
        log "INFO" "Successfully extracted '$backup_file'."
    else
        log "ERROR" "Extraction of '$backup_file' failed with status $extract_status."
    fi
    return $extract_status
}

# --- WP-CLI Command Wrapper ---
# Runs WP-CLI commands, handling --allow-root if script is run as root.
# Args:
#   $@: arguments to pass to wp-cli
wp_cli() {
    local args=("$@")
    local wp_cmd="wp"
    local nice_prefix="nice -n ${NICE_LEVEL:-19}"

    if ! command_exists wp; then
        log "ERROR" "WP-CLI command (wp) not found. Please install and configure WP-CLI."
        return 127 # Command not found status
    fi

    if [ "$(id -u)" -eq 0 ]; then # Check if running as root
        log "DEBUG" "Running WP-CLI as root with --allow-root"
        $nice_prefix $wp_cmd "${args[@]}" --allow-root
    else
        $nice_prefix $wp_cmd "${args[@]}"
    fi
    return $?
}

# --- Filename Suffix Sanitization ---
# Cleans a string for safe use in filenames.
# Args:
#   $1: suffix_string
# Returns: sanitized string via echo
sanitize_filename_suffix() {
    local suffix_input="$1"
    local sanitized_suffix

    # 1. Replace whitespace and dots with underscore
    sanitized_suffix=$(echo "$suffix_input" | sed -e 's/[[:space:].]/_/g')
    # 2. Remove all characters that are not alphanumeric, underscore, or hyphen
    sanitized_suffix=$(echo "$sanitized_suffix" | tr -cd '[:alnum:]_-')
    # 3. Replace multiple hyphens/underscores with a single instance
    sanitized_suffix=$(echo "$sanitized_suffix" | sed -e 's/--\+/-/g' -e 's/__\+/_/g')
    # 4. Remove leading/trailing hyphens or underscores
    sanitized_suffix=$(echo "$sanitized_suffix" | sed -e 's/^[_-]*//' -e 's/[_-]*$//')
    # 5. Optional: Convert to lowercase
    # sanitized_suffix=$(echo "$sanitized_suffix" | tr '[:upper:]' '[:lower:]')
    # 6. Limit length to prevent overly long filenames (e.g., 50 characters)
    sanitized_suffix=${sanitized_suffix:0:50}

    echo "$sanitized_suffix"
}


# --- Global Trap for Cleanup ---
# This trap is set when common.sh is sourced. It will apply to the sourcing script.
# The cleanup function is defined above.
# Note: Traps in sourced files can be complex. Ensure this behavior is desired for all scripts.
# Individual scripts can set their own traps which might override or supplement this.
trap 'cleanup "Sourced Script" "Common Trap"' EXIT INT TERM
# Removed previous trap as it was too generic for INT/TERM and could be set per script more specifically.
# The EXIT trap is generally useful for common cleanup.

log "DEBUG" "common.sh sourced successfully. SCRIPTPATH: $SCRIPTPATH"