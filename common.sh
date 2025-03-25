#!/usr/bin/env bash

# Common variables
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=$(date +"%Y%m%d-%H%M%S")
START_TIME=$(date +%s)
ERROR_LOG="$SCRIPTPATH/errors.log"

# Logging function with advanced levels
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "${LOG_LEVEL:-normal}" in
        verbose)
            [ -n "$LOG_FILE" ] && echo "$timestamp - [$level] $message" >> "$LOG_FILE"
            echo "$timestamp - [$level] $message" >&2
            ;;
        normal)
            if [ "$level" != "DEBUG" ]; then
                [ -n "$LOG_FILE" ] && echo "$timestamp - [$level] $message" >> "$LOG_FILE"
                echo "$timestamp - [$level] $message" >&2
            fi
            ;;
        minimal)
            if [ "$level" = "ERROR" ] || [ "$level" = "INFO" ]; then
                [ -n "$LOG_FILE" ] && echo "$timestamp - [$level] $message" >> "$LOG_FILE"
                echo "$timestamp - [$level] $message" >&2
            fi
            ;;
    esac
}

# Status update function
update_status() {
    local status="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -n "$STATUS_LOG" ]; then
        echo "$timestamp - [$status] $message" >> "$STATUS_LOG"
    fi
}

# Notification function with multiple methods
notify() {
    local status="$1"
    local message="$2"
    local subject_prefix="$3"
    local project_name=$(basename "${CONFIG_FILE:-unknown}" .conf)
    local notify_methods="${NOTIFY_METHOD:-email}"

    IFS=',' read -ra methods <<< "$notify_methods"
    for method in "${methods[@]}"; do
        case "$method" in
            email)
                if [ -n "$NOTIFY_EMAIL" ] && command -v mail >/dev/null 2>&1; then
                    echo "$message" | mail -s "$subject_prefix $status: $project_name" "$NOTIFY_EMAIL"
                    log "DEBUG" "Email notification sent to $NOTIFY_EMAIL: $status - $message"
                elif [ -n "$NOTIFY_EMAIL" ]; then
                    log "WARNING" "Mail command not found, email notification not sent"
                fi
                ;;
            slack)
                if [ -n "$SLACK_WEBHOOK_URL" ] && command -v curl >/dev/null 2>&1; then
                    local slack_message="{\"text\": \"$subject_prefix $status: $project_name - $message\"}"
                    curl -X POST -H 'Content-type: application/json' --data "$slack_message" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
                    log "DEBUG" "Slack notification sent: $status - $message"
                elif [ -n "$SLACK_WEBHOOK_URL" ]; then
                    log "WARNING" "curl not found, Slack notification not sent"
                fi
                ;;
            telegram)
                if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && command -v curl >/dev/null 2>&1; then
                    local telegram_message="$subject_prefix $status: $project_name - $message"
                    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                         -d chat_id="$TELEGRAM_CHAT_ID" -d text="$telegram_message" >/dev/null 2>&1
                    log "DEBUG" "Telegram notification sent: $status - $message"
                elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                    log "WARNING" "curl not found, Telegram notification not sent"
                fi
                ;;
            *)
                log "WARNING" "Unknown NOTIFY_METHOD: $method, skipping"
                ;;
        esac
    done
}

# Error reporting function
report_error() {
    local exit_code="$1"
    local task="$2"
    local subject_prefix="${3:-Operation}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local error_message="$task failed with exit code $exit_code"

    log "ERROR" "$error_message"
    echo "$timestamp - $error_message" >> "$ERROR_LOG"
    update_status "FAILURE" "$task"
    notify "FAILURE" "$error_message" "$subject_prefix"
    exit 1
}

# Check command status
check_status() {
    local status="$1"
    local message="$2"
    local context="${3:-Operation}"
    if [ "$status" -ne 0 ]; then
        report_error "$status" "$message" "$context"
    else
        log "DEBUG" "$message succeeded"
    fi
}

# Compression function
compress() {
    local src="$1"
    local dest="$2"
    local context="${3:-Operation}"
    case "${COMPRESSION_FORMAT:-tar.gz}" in
        tar.gz)
            if command -v pigz >/dev/null 2>&1; then
                nice -n "${NICE_LEVEL:-19}" tar -c "$src" | pigz -9 > "$dest"
                check_status $? "Compressing $src with pigz" "$context"
            else
                nice -n "${NICE_LEVEL:-19}" tar -czf "$dest" "$src"
                check_status $? "Compressing $src with tar" "$context"
            fi
            ;;
        zip)
            nice -n "${NICE_LEVEL:-19}" zip -r9 "$dest" "$src"
            check_status $? "Compressing $src with zip" "$context"
            ;;
        tar)
            nice -n "${NICE_LEVEL:-19}" tar -cf "$dest" "$src"
            check_status $? "Compressing $src with tar (no compression)" "$context"
            ;;
        *)
            log "ERROR" "Unsupported compression format: $COMPRESSION_FORMAT"
            report_error 1 "Unsupported compression format: $COMPRESSION_FORMAT" "$context"
            ;;
    esac
}

# Decompression function
decompress() {
    local src="$1"
    local dest="$2"
    local context="${3:-Operation}"
    case "$src" in
        *.tar.gz)
            nice -n "${NICE_LEVEL:-19}" tar -xzf "$src" -C "$dest"
            check_status $? "Decompressing $src with tar.gz" "$context"
            ;;
        *.zip)
            nice -n "${NICE_LEVEL:-19}" unzip "$src" -d "$dest"
            check_status $? "Decompressing $src with zip" "$context"
            ;;
        *.tar)
            nice -n "${NICE_LEVEL:-19}" tar -xf "$src" -C "$dest"
            check_status $? "Decompressing $src with tar" "$context"
            ;;
        *)
            log "ERROR" "Unsupported compression format for $src"
            report_error 1 "Unsupported compression format for $src" "$context"
            ;;
    esac
}

# Function to load and decrypt config file
load_config() {
    local config_file="$1"
    local decrypted_file="${config_file}.decrypted"
    local passphrase_file="${HOME}/.gpg-passphrase"

    if [[ "$config_file" =~ \.gpg$ ]]; then
        if ! command -v gpg >/dev/null 2>&1; then
            log "ERROR" "gpg is not installed! Please install it with 'sudo apt install gnupg'."
            report_error 1 "gpg not installed" "ConfigLoading"
        fi
        log "INFO" "Decrypting config file: $config_file"
        if [ -n "$CONFIG_PASSPHRASE" ]; then
            gpg --batch --yes --passphrase "$CONFIG_PASSPHRASE" -d "$config_file" > "$decrypted_file" 2>/dev/null
        elif [ -f "$passphrase_file" ]; then
            gpg --batch --yes --passphrase-file "$passphrase_file" -d "$config_file" > "$decrypted_file" 2>/dev/null
        else
            log "ERROR" "No passphrase provided and $passphrase_file not found!"
            report_error 1 "Passphrase not provided" "ConfigLoading"
        fi
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to decrypt $config_file. Wrong passphrase or corrupted file."
            rm -f "$decrypted_file"
            report_error 1 "Decryption failed for $config_file" "ConfigLoading"
        fi
        chmod 600 "$decrypted_file"
        log "DEBUG" "Config file decrypted: $decrypted_file"
        echo "source $decrypted_file"
    else
        echo "source $config_file"
    fi
}

# Cleanup function for interruptions and decrypted files
cleanup() {
    local context="${1:-Process}"
    local subject_prefix="${2:-Operation}"
    log "INFO" "Script interrupted or finished! Cleaning up..."
    if [ -n "$CONFIG_FILE" ] && [ -f "${CONFIG_FILE}.decrypted" ]; then
        rm -f "${CONFIG_FILE}.decrypted"
        log "INFO" "Cleaned up decrypted file: ${CONFIG_FILE}.decrypted"
    fi
    update_status "INTERRUPTED" "$context for $DIR"
    notify "INTERRUPTED" "$context for $DIR interrupted or completed" "$subject_prefix"
}

# Trap interruptions and exit
trap 'cleanup "Process" "Operation"' INT TERM EXIT