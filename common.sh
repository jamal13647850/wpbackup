#!/bin/bash
# common.sh - Common functions and variables for WordPress backup scripts
# Author: System Administrator
# Last updated: 2025-05-16

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TIME=$(date +%s)
DIR=$(date +%Y%m%d-%H%M%S)

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default log files
LOG_FILE="${LOG_FILE:-$SCRIPTPATH/script.log}"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/status.log}"

# Logging function with colored output
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Skip DEBUG messages if not in verbose mode
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "verbose" ]; then
        return
    fi

    # Always write to log file
    echo -e "${timestamp} - [$level] $message" >> "$LOG_FILE"

    # Display colored output to terminal based on log level
    case "$level" in
        "ERROR")
            echo -e "${timestamp} - ${RED}${BOLD}[$level]${NC} $message"
            ;;
        "WARNING")
            echo -e "${timestamp} - ${YELLOW}${BOLD}[$level]${NC} $message"
            ;;
        "INFO")
            if [ "$LOG_LEVEL" = "verbose" ]; then
                echo -e "${timestamp} - ${GREEN}[$level]${NC} $message"
            fi
            ;;
        "DEBUG")
            echo -e "${timestamp} - ${CYAN}[$level]${NC} $message"
            ;;
        *)
            echo -e "${timestamp} - [$level] $message"
            ;;
    esac
}

# Update status log
update_status() {
    local status="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "${timestamp} - [${status}] ${message}" >> "$STATUS_LOG"
}

# Check command status and handle errors
check_status() {
    local status=$1
    local operation=$2
    local process_type=$3

    if [ $status -ne 0 ]; then
        log "ERROR" "$operation failed with status $status"
        update_status "FAILED" "$operation failed with status $status"
        notify "FAILED" "$operation failed with status $status" "$process_type"
        echo -e "${RED}${BOLD}Error:${NC} $operation failed with status $status"
        exit $status
    else
        log "DEBUG" "$operation completed successfully"
    fi
}

# Send notifications based on configuration
notify() {
    local status="$1"
    local message="$2"
    local process_type="$3"

    # Skip if notification method is not set
    if [ -z "$NOTIFY_METHOD" ]; then
        return
    fi

    # Process comma-separated notification methods
    IFS=',' read -ra METHODS <<< "$NOTIFY_METHOD"
    for method in "${METHODS[@]}"; do
        case "$method" in
            "email")
                if [ -n "$NOTIFY_EMAIL" ]; then
                    echo "$message" | mail -s "[$status] $process_type Process" "$NOTIFY_EMAIL"
                    log "INFO" "Email notification sent to $NOTIFY_EMAIL"
                fi
                ;;
            "slack")
                if [ -n "$SLACK_WEBHOOK_URL" ]; then
                    curl -s -X POST -H 'Content-type: application/json' \
                        --data "{\"text\":\"[$status] $process_type Process: $message\"}" \
                        "$SLACK_WEBHOOK_URL"
                    log "INFO" "Slack notification sent"
                fi
                ;;
            "telegram")
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                    curl -s -X POST \
                        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                        -d chat_id="$TELEGRAM_CHAT_ID" \
                        -d text="[$status] $process_type Process: $message"
                    log "INFO" "Telegram notification sent"
                fi
                ;;
        esac
    done
}

# Compress files with specified format
compress() {
    local source="$1"
    local output="$2"

    case "${output##*.}" in
        "zip")
            nice -n "$NICE_LEVEL" zip -r "$output" "$source"
            ;;
        "gz"|"tgz")
            if [[ "$output" == *tar.gz ]]; then
                nice -n "$NICE_LEVEL" tar -czf "$output" "$source"
            else
                nice -n "$NICE_LEVEL" gzip -c "$source" > "$output"
            fi
            ;;
        "bz2")
            if [[ "$output" == *tar.bz2 ]]; then
                nice -n "$NICE_LEVEL" tar -cjf "$output" "$source"
            else
                nice -n "$NICE_LEVEL" bzip2 -c "$source" > "$output"
            fi
            ;;
        "xz")
            if [[ "$output" == *tar.xz ]]; then
                nice -n "$NICE_LEVEL" tar -cJf "$output" "$source"
            else
                nice -n "$NICE_LEVEL" xz -c "$source" > "$output"
            fi
            ;;
        *)
            # Default to tar if format not recognized
            nice -n "$NICE_LEVEL" tar -cf "$output" "$source"
            ;;
    esac

    return $?
}

# Interactive config file selection
select_config_file() {
    local config_dir="$1"
    local script_type="$2"
    local configs=()
    local i=0

    # Check if config directory exists
    if [ ! -d "$config_dir" ]; then
        echo -e "${RED}${BOLD}Error: Config directory $config_dir not found!${NC}" >&2
        return 1
    fi

    # List regular config files first
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$config_dir" -type f -name "*.conf" | sort)

    # Then list encrypted config files
    while IFS= read -r file; do
        configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}"
        ((i++))
    done < <(find "$config_dir" -type f -name "*.conf.gpg" | sort)

    # Check if any config files were found
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No configuration files found in $config_dir!${NC}" >&2
        return 1
    fi

    # Prompt user to select a config file
    echo -e "${GREEN}Select a configuration file by number:${NC}"
    read -p "> " selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi

    # Set the selected config file
    CONFIG_FILE="${configs[$selection]}"
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    return 0
}

# Function for cleanup operations
cleanup() {
    local process_name="$1"
    local process_type="$2"

    log "INFO" "Script interrupted or finished! Cleaning up..."
    update_status "INTERRUPTED" "Process for $DIR"

    # Kill any background processes
    jobs -p | xargs -r kill

    return 0
}

# Load and decrypt config file if necessary
load_config() {
    local config_file="$1"

    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        echo "echo -e \"${RED}${BOLD}Error: Configuration file $config_file not found!${NC}\" >&2; exit 1"
        return 1
    fi

    # Handle encrypted config files
    if [[ "$config_file" =~ \.gpg$ ]]; then
        # Check if gpg is installed
        if ! command -v gpg &>/dev/null; then
            echo "echo -e \"${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}\" >&2; exit 1"
            return 1
        fi

        # Decrypt the config file
        gpg --quiet --decrypt "$config_file" 2>/dev/null
    else
        # Output the content of a regular config file
        cat "$config_file"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
check_requirements() {
    local missing_commands=()

    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -gt 0 ]; then
        echo -e "${RED}${BOLD}Error: Required commands not found: ${missing_commands[*]}${NC}" >&2
        echo -e "${YELLOW}Please install the missing packages and try again.${NC}" >&2
        return 1
    fi

    return 0
}

# Initialize log file with header
init_log() {
    local script_name="$1"
    echo "----------------------------------------" >> "$LOG_FILE"
    echo "Starting $script_name at $(date)" >> "$LOG_FILE"
    echo "----------------------------------------" >> "$LOG_FILE"
}

# Format duration in human-readable format
format_duration() {
    local seconds=$1
    local days=$((seconds/86400))
    local hours=$(( (seconds%86400)/3600 ))
    local minutes=$(( (seconds%3600)/60 ))
    local remaining_seconds=$((seconds%60))

    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m ${remaining_seconds}s"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${remaining_seconds}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${remaining_seconds}s"
    else
        echo "${remaining_seconds}s"
    fi
}

# Convert bytes to human-readable size
human_readable_size() {
    local size=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0

    while [ $size -ge 1024 ] && [ $unit -lt 4 ]; do
        size=$((size/1024))
        ((unit++))
    done

    echo "$size${units[$unit]}"
}

# Set up trap to handle interruptions
trap 'cleanup "Script" "Process"' INT TERM
