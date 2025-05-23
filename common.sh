#!/bin/bash
# File: common.sh

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" #
START_TIME=$(date +%s) #
DIR=$(date +%Y%m%d-%H%M%S) #

# Color Codes
RED='\033[0;31m' #
GREEN='\033[0;32m' #
YELLOW='\033[0;33m' #
BLUE='\033[0;34m' #
PURPLE='\033[0;35m' #
CYAN='\033[0;36m' #
WHITE='\033[0;37m' #
BOLD='\033[1m' #
NC='\033[0m' #

# Log and Status Files
LOG_FILE="${LOG_FILE:-$SCRIPTPATH/logs/script.log}" #
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/status.log}" #

# Function to log messages
log() {
    local level="$1" #
    local message="$2" #
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S") #

    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "verbose" ]; then #
        return
    fi

    echo -e "${timestamp} - [$level] $message" >> "$LOG_FILE" #

    case "$level" in
        "ERROR") #
            echo -e "${timestamp} - ${RED}${BOLD}[$level]${NC} $message" #
            ;;
        "WARNING") #
            echo -e "${timestamp} - ${YELLOW}${BOLD}[$level]${NC} $message" #
            ;;
        "INFO") #
            if [ "$LOG_LEVEL" = "verbose" ]; then #
                echo -e "${timestamp} - ${GREEN}[$level]${NC} $message" #
            fi
            ;;
        "DEBUG") #
            echo -e "${timestamp} - ${CYAN}[$level]${NC} $message" #
            ;;
        *) #
            echo -e "${timestamp} - [$level] $message" #
            ;;
    esac
}

# Function to update status log
update_status() {
    local status="$1" #
    local message="$2" #
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S") #
    echo "${timestamp} - [${status}] ${message}" >> "$STATUS_LOG" #
}

# Function to check command status and exit on failure
check_status() {
    local status=$1 #
    local operation=$2 #
    local process_type=$3 #

    if [ $status -ne 0 ]; then #
        log "ERROR" "$operation failed with status $status" #
        update_status "FAILED" "$operation failed with status $status" #
        notify "FAILED" "$operation failed with status $status" "$process_type" #
        echo -e "${RED}${BOLD}Error:${NC} $operation failed with status $status" #
        exit $status #
    else
        log "DEBUG" "$operation completed successfully" #
    fi
}

# Function to send notifications
notify() {
    local status="$1" #
    local message="$2" #
    local process_type="$3" #
    local attachment_path="${4:-}" #
    local hostname=$(hostname) #
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S") #
    local full_message="[$status] $process_type Process on $hostname at $timestamp\n\n$message" #

    if [ -z "$NOTIFY_METHOD" ]; then #
        log "DEBUG" "No notification method configured, skipping notifications" #
        return
    fi

    log "DEBUG" "Sending notifications via: $NOTIFY_METHOD" #

    IFS=',' read -ra METHODS <<< "$NOTIFY_METHOD" #
    for method in "${METHODS[@]}"; do #
        case "$method" in
            "email") #
                if [ -n "$NOTIFY_EMAIL" ]; then #
                    log "DEBUG" "Sending email notification to $NOTIFY_EMAIL" #
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then #
                        echo -e "$full_message" | mail -s "[$status] $process_type Process on $hostname" -a "$attachment_path" "$NOTIFY_EMAIL" #
                        log "INFO" "Email notification with attachment sent to $NOTIFY_EMAIL" #
                    else
                        echo -e "$full_message" | mail -s "[$status] $process_type Process on $hostname" "$NOTIFY_EMAIL" #
                        log "INFO" "Email notification sent to $NOTIFY_EMAIL" #
                    fi
                else
                    log "WARNING" "Email notification requested but NOTIFY_EMAIL is not set" #
                fi
                ;;
            "slack") #
                if [ -n "$SLACK_WEBHOOK_URL" ]; then #
                    log "DEBUG" "Sending Slack notification" #
                    local slack_message="{\"blocks\":[{\"type\":\"header\",\"text\":{\"type\":\"plain_text\",\"text\":\"[$status] $process_type Process\"}},{\"type\":\"section\",\"fields\":[{\"type\":\"mrkdwn\",\"text\":\"*Host:*\\n$hostname\"},{\"type\":\"mrkdwn\",\"text\":\"*Time:*\\n$timestamp\"}]},{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"$message\"}}]}" #
                    curl -s -X POST -H 'Content-type: application/json' --data "$slack_message" "$SLACK_WEBHOOK_URL" #
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ] && [ -n "$SLACK_API_TOKEN" ]; then #
                        log "DEBUG" "Uploading attachment to Slack" #
                        curl -F file=@"$attachment_path" \
                             -F "initial_comment=Attachment for [$status] $process_type Process" \
                             -F channels="$SLACK_CHANNEL" \
                             -H "Authorization: Bearer $SLACK_API_TOKEN" \
                             https://slack.com/api/files.upload #
                        log "INFO" "Slack notification with attachment sent" #
                    else
                        log "INFO" "Slack notification sent" #
                    fi
                else
                    log "WARNING" "Slack notification requested but SLACK_WEBHOOK_URL is not set" #
                fi
                ;;
            "telegram") #
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then #
                    log "DEBUG" "Sending Telegram notification" #
                    local telegram_message="*[$status] $process_type Process on $hostname*\n_$timestamp_\n\n$message" #
                    telegram_message=$(echo -n "$telegram_message" | sed 's/&/%26/g; s/#/%23/g; s/;/%3B/g; s/+/%2B/g; s/,/%2C/g; s/?/%3F/g; s/:/%3A/g; s/@/%40/g; s/=/%3D/g; s/\//%2F/g') #
                    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$telegram_message" -d parse_mode="Markdown" #
                    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then #
                        log "DEBUG" "Uploading attachment to Telegram" #
                        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID" -F document=@"$attachment_path" -F caption="Attachment for [$status] $process_type Process" #
                        log "INFO" "Telegram notification with attachment sent" #
                    else
                        log "INFO" "Telegram notification sent" #
                    fi
                else
                    log "WARNING" "Telegram notification requested but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is not set" #
                fi
                ;;
        esac
    done
}

# Function to compress files/directories
compress() {
    local source="$1" #
    local output="$2" #

    case "${output##*.}" in
        "zip") #
            nice -n "$NICE_LEVEL" zip -r "$output" "$source" #
            ;;
        "gz"|"tgz") #
            if [[ "$output" == *tar.gz ]]; then #
                nice -n "$NICE_LEVEL" tar -czf "$output" "$source" #
            else
                nice -n "$NICE_LEVEL" gzip -c "$source" > "$output" #
            fi
            ;;
        "bz2") #
            if [[ "$output" == *tar.bz2 ]]; then #
                nice -n "$NICE_LEVEL" tar -cjf "$output" "$source" #
            else
                nice -n "$NICE_LEVEL" bzip2 -c "$source" > "$output" #
            fi
            ;;
        "xz") #
            if [[ "$output" == *tar.xz ]]; then #
                nice -n "$NICE_LEVEL" tar -cJf "$output" "$source" #
            else
                nice -n "$NICE_LEVEL" xz -c "$source" > "$output" #
            fi
            ;;
        *) #
            nice -n "$NICE_LEVEL" tar -cf "$output" "$source" #
            ;;
    esac

    return $? #
}

# Function to select configuration file
select_config_file() {
    local config_dir="$1" #
    local script_type="$2" #
    local configs=() #
    local i=0 #

    if [ ! -d "$config_dir" ]; then #
        echo -e "${RED}${BOLD}Error: Config directory $config_dir not found!${NC}" >&2 #
        return 1
    fi

    while IFS= read -r file; do #
        if [[ "$file" != *".gpg" ]]; then #
            configs+=("$file") #
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}" #
            ((i++)) #
        fi
    done < <(find "$config_dir" -type f -name "*.conf" | sort) #

    while IFS= read -r file; do #
        configs+=("$file") #
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}" #
        ((i++)) #
    done < <(find "$config_dir" -type f -name "*.conf.gpg" | sort) #

    if [ ${#configs[@]} -eq 0 ]; then #
        echo -e "${RED}${BOLD}Error: No configuration files found in $config_dir!${NC}" >&2 #
        return 1
    fi

    echo -e "${GREEN}Select a configuration file by number:${NC}" #
    read -p "> " selection #

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then #
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2 #
        return 1
    fi

    CONFIG_FILE="${configs[$selection]}" #
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}" #

    return 0
}

# Function for cleanup operations
cleanup() {
    local process_name="$1" #
    local process_type="$2" #

    log "INFO" "Script interrupted or finished! Cleaning up..." #
    update_status "INTERRUPTED" "Process for $DIR" #

    jobs -p | xargs -r kill #

    return 0 #
}

# Function to load config (used internally or for debugging)
load_config() {
    local config_file="$1" #

    if [ ! -f "$config_file" ]; then #
        echo "echo -e \"${RED}${BOLD}Error: Configuration file $config_file not found!${NC}\" >&2; exit 1" #
        return 1
    fi

    if [[ "$config_file" =~ \.gpg$ ]]; then #
        if ! command -v gpg &>/dev/null; then #
            echo "echo -e \"${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}\" >&2; exit 1" #
            return 1
        fi
        gpg --quiet --decrypt "$config_file" 2>/dev/null #
    else
        cat "$config_file" #
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1 #
}

# Function to check for required commands
check_requirements() {
    local missing_commands=() #

    for cmd in "$@"; do #
        if ! command_exists "$cmd"; then #
            missing_commands+=("$cmd") #
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then #
        echo -e "${RED}${BOLD}Error: Required commands not found: ${missing_commands[*]}${NC}" >&2 #
        echo -e "${YELLOW}Please install the missing packages and try again.${NC}" >&2 #
        return 1
    fi

    return 0
}

# Function to initialize log file for a script
init_log() {
    local script_name="$1" #
    # Create logs directory if it doesn't exist
    mkdir -p "$SCRIPTPATH/logs"
    echo "----------------------------------------" >> "$LOG_FILE" #
    echo "Starting $script_name at $(date)" >> "$LOG_FILE" #
    echo "----------------------------------------" >> "$LOG_FILE" #
}

# Function to format duration from seconds to human-readable format
format_duration() {
    local seconds=$1 #
    local days=$((seconds/86400)) #
    local hours=$(( (seconds%86400)/3600 )) #
    local minutes=$(( (seconds%3600)/60 )) #
    local remaining_seconds=$((seconds%60)) #

    if [ $days -gt 0 ]; then #
        echo "${days}d ${hours}h ${minutes}m ${remaining_seconds}s" #
    elif [ $hours -gt 0 ]; then #
        echo "${hours}h ${minutes}m ${remaining_seconds}s" #
    elif [ $minutes -gt 0 ]; then #
        echo "${minutes}m ${remaining_seconds}s" #
    else
        echo "${remaining_seconds}s" #
    fi
}

# Function to convert size to human-readable format
human_readable_size() {
    local size=$1 #
    local units=("B" "KB" "MB" "GB" "TB") #
    local unit=0 #

    while [ "$size" -ge 1024 ] && [ "$unit" -lt 4 ]; do #
        size=$((size/1024)) #
        ((unit++)) #
    done

    echo "$size${units[$unit]}" #
}

# Function to process (source) configuration file
process_config_file() {
    local config_file="$1" #
    local script_type="$2" #

    if [ ! -f "$config_file" ]; then #
        echo -e "${RED}${BOLD}Error: Configuration file $config_file not found!${NC}" >&2 #
        exit 1
    fi

    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$config_file")${NC}" #

    if [[ "$config_file" =~ \.gpg$ ]]; then #
        if ! command_exists gpg; then #
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2 #
            exit 1
        fi
        echo -e "${CYAN}Loading encrypted configuration file...${NC}" #
        eval "$(gpg --quiet --decrypt "$config_file" 2>/dev/null)" #
        if [ $? -ne 0 ]; then #
            echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2 #
            exit 1
        fi
        log "INFO" "Successfully loaded encrypted configuration file: $(basename "$config_file")" #
    else
        . "$config_file" #
        log "INFO" "Successfully loaded configuration file: $(basename "$config_file")" #
    fi
}

# Function to validate SSH connection
validate_ssh() {
    local user="$1" #
    local ip="$2" #
    local port="$3" #
    local key_path="$4" #
    local process_type="$5" #

    echo -e "${CYAN}${BOLD}Validating SSH connection...${NC}" #
    ssh -p "${port:-22}" -i "$key_path" "$user@$ip" "echo OK" >/dev/null 2>&1 #
    check_status $? "SSH connection validation" "$process_type" #
}

# Function to extract backup archives
extract_backup() {
    local backup_file="$1" #
    local extract_dir="$2" #

    mkdir -p "$extract_dir" #

    case "${backup_file##*.}" in
        "zip") #
            nice -n "$NICE_LEVEL" unzip -o "$backup_file" -d "$extract_dir" #
            ;;
        "gz"|"tgz") #
            if [[ "$backup_file" == *tar.gz ]]; then #
                nice -n "$NICE_LEVEL" tar -xzf "$backup_file" -C "$extract_dir" #
            else
                nice -n "$NICE_LEVEL" gunzip -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .gz)" #
            fi
            ;;
        "bz2") #
            if [[ "$backup_file" == *tar.bz2 ]]; then #
                nice -n "$NICE_LEVEL" tar -xjf "$backup_file" -C "$extract_dir" #
            else
                nice -n "$NICE_LEVEL" bunzip2 -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .bz2)" #
            fi
            ;;
        "xz") #
            if [[ "$backup_file" == *tar.xz ]]; then #
                nice -n "$NICE_LEVEL" tar -xJf "$backup_file" -C "$extract_dir" #
            else
                nice -n "$NICE_LEVEL" unxz -c "$backup_file" > "$extract_dir/$(basename "$backup_file" .xz)" #
            fi
            ;;
        *) #
            nice -n "$NICE_LEVEL" tar -xf "$backup_file" -C "$extract_dir" #
            ;;
    esac

    return $? #
}

# Function to run WP-CLI commands
wp_cli() {
    local args=("$@") #
    if [ "$EUID" -eq 0 ]; then #
        nice -n "$NICE_LEVEL" wp "${args[@]}" --allow-root #
    else
        nice -n "$NICE_LEVEL" wp "${args[@]}" #
    fi
}

# Trap for cleanup on exit/interrupt
trap 'cleanup "Script" "Process"' INT TERM #


# Function to sanitize a string to be used as part of a filename
sanitize_filename_suffix() {
    local suffix="$1"
    # 1. Replace common separators (space, dot, etc.) with an underscore
    suffix=$(echo "$suffix" | sed -e 's/[[:space:].]/_/g')
    # 2. Remove all characters that are not alphanumeric, underscore, or hyphen
    suffix=$(echo "$suffix" | tr -cd '[:alnum:]_-')
    # 3. Replace multiple hyphens/underscores with a single one of each
    suffix=$(echo "$suffix" | sed -e 's/--\+/-/g' -e 's/__\+/_/g')
    # 4. Remove leading/trailing hyphens or underscores
    suffix=$(echo "$suffix" | sed -e 's/^[_-]*//' -e 's/[_-]*$//')
    # 5. Optional: Convert to lowercase (uncomment if desired)
    # suffix=$(echo "$suffix" | tr '[:upper:]' '[:lower:]')
    # 6. Limit length (e.g., max 50 chars)
    suffix=${suffix:0:50}
    echo "$suffix"
}