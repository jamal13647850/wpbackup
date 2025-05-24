#!/bin/bash
# --- Signature ---
# Author: Sayyed Jamal Ghasemi
# Full Stack Developer
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
# --- END Signature ---

# --- Script Information ---
# This script provides a setup utility for a WordPress backup system.
# It includes functionalities for creating configurations, setting up cron jobs,
# testing SSH connections, managing encryption of config files, and more.

# Get the absolute path of the directory where this script resides
SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- ANSI Color Codes for Output Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Helper Functions ---

# Checks if a given command is available in the system's PATH.
# Arguments:
#   $1: Command name to check.
# Returns:
#   0 if the command exists, 1 otherwise.
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Applies secure permissions (600) to a configuration file.
# Optionally changes ownership to root:root if chown is available.
# Arguments:
#   $1: Path to the configuration file.
apply_config_permissions() {
    local config_file="$1"
    chmod 600 "$config_file" # Set permissions to read/write for owner only
    if command_exists chown; then
        sudo chown root:root "$config_file" 2>/dev/null || true # Attempt to change owner, ignore errors
    fi
    if [ "$(stat -c "%a" "$config_file")" != "600" ]; then
        echo -e "${YELLOW}Warning: Could not set file mode 600 on $config_file${NC}"
    fi
}

# Checks if all specified commands are installed.
# Arguments:
#   $@: A list of command names to check.
# Returns:
#   0 if all commands exist, 1 if any are missing.
check_requirements() {
    local missing_commands=()
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo -e "${RED}${BOLD}Error: Required command(s) not found: ${missing_commands[*]}${NC}" >&2
        echo -e "${YELLOW}Please install the missing package(s) and try again.${NC}" >&2
        return 1
    fi
    return 0
}

# Creates a directory if it does not already exist.
# Arguments:
#   $1: Path of the directory to create.
# Returns:
#   0 if directory exists or is created successfully, 1 on failure.
create_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo -e "${CYAN}Creating directory: $dir${NC}"
        mkdir -p "$dir" # Create directory and any parent directories if needed
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to create directory $dir${NC}" >&2
            return 1
        fi
    else
        echo -e "${GREEN}Directory already exists: $dir${NC}"
    fi
    return 0
}

# Sets permissions for a file or directory.
# Arguments:
#   $1: Path to the file or directory.
#   $2: Permissions to set (e.g., "755", "600").
# Returns:
#   0 on success, 1 on failure.
set_permissions() {
    local path="$1"
    local perms="$2"
    echo -e "${CYAN}Setting permissions $perms on $path${NC}"
    chmod -R "$perms" "$path" # Set permissions recursively
    if [ $? -ne 0 ]; then
        echo -e "${RED}${BOLD}Error: Failed to set permissions on $path${NC}" >&2
        return 1
    fi
    return 0
}

# Guides the user through creating a new backup configuration file.
# Arguments:
#   $1: Name for the configuration (without .conf extension).
# Returns:
#   0 on success or if aborted by user, 1 on error during file creation.
create_config() {
    local config_name="$1"
    local config_file="$SCRIPTPATH/configs/$config_name.conf"
    local notify_email=""
    local slack_webhook=""
    local telegram_token=""
    local telegram_chat_id=""

    if [ -f "$config_file" ]; then
        echo -e "${YELLOW}${BOLD}Warning: Configuration file $config_name.conf already exists.${NC}"
        read -p "Do you want to overwrite it? (y/n): " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo -e "${YELLOW}Configuration creation aborted.${NC}"
            return 0
        fi
    fi

    echo -e "${CYAN}${BOLD}Creating a new configuration file: $config_name.conf${NC}"

    echo -e "${GREEN}Enter SSH settings:${NC}"
    read -p "SSH Port (default: 22): " ssh_port
    ssh_port="${ssh_port:-22}"
    read -p "SSH Username: " ssh_user
    while [ -z "$ssh_user" ]; do
        echo -e "${YELLOW}SSH Username cannot be empty.${NC}"
        read -p "SSH Username: " ssh_user
    done
    read -p "SSH Server IP: " ssh_ip
    while [ -z "$ssh_ip" ]; do
        echo -e "${YELLOW}SSH Server IP cannot be empty.${NC}"
        read -p "SSH Server IP: " ssh_ip
    done
    read -p "Remote DB Backup Path: " db_path
    while [ -z "$db_path" ]; do
        echo -e "${YELLOW}Remote DB Backup Path cannot be empty.${NC}"
        read -p "Remote DB Backup Path: " db_path
    done
    read -p "Remote Files Backup Path: " files_path
    while [ -z "$files_path" ]; do
        echo -e "${YELLOW}Remote Files Backup Path cannot be empty.${NC}"
        read -p "Remote Files Backup Path: " files_path
    done
    read -p "SSH Private Key Path (default: ~/.ssh/id_rsa): " key_path
    key_path="${key_path:-$HOME/.ssh/id_rsa}"

    echo -e "${GREEN}Enter WordPress settings:${NC}"
    read -p "WordPress Path (absolute): " wp_path
    while [ -z "$wp_path" ]; do
        echo -e "${YELLOW}WordPress Path cannot be empty.${NC}"
        read -p "WordPress Path: " wp_path
    done
    read -p "Max File Size for Backup (default: 50m): " max_size
    max_size="${max_size:-50m}"
    read -p "Backup directory base path for local backups (default: $SCRIPTPATH/local_backups): " local_backup_dir
    local_backup_dir="${local_backup_dir:-$SCRIPTPATH/local_backups}"

    echo -e "${GREEN}Enter advanced backup naming and compression settings:${NC}"
    read -p "Backup folder name format (default: date +%Y%m%d-%H%M%S): " dir_name_fmt
    dir_name_fmt="${dir_name_fmt:-\$(date +%Y%m%d-%H%M%S)}"
    read -p "Database backup file prefix (default: DB): " db_file_prefix
    db_file_prefix="${db_file_prefix:-DB}"
    read -p "Files backup file prefix (default: Files): " files_file_prefix
    files_file_prefix="${files_file_prefix:-Files}"
    read -p "Compression format [zip, tar.gz, tar] (default: tar.gz): " compression_format
    compression_format="${compression_format:-tar.gz}"

    echo -e "${GREEN}Backup Storage Location (for scripts with storage mode selection):${NC}"
    read -p "Backup storage location? [local/remote/both] (default: both): " backup_location
    backup_location="${backup_location:-both}"

    echo -e "${GREEN}Enter file/folder patterns to exclude from backups (comma-separated, default: wp-staging,*.log,cache,wpo-cache,wp-content/cache,wp-content/debug.log):${NC}"
    read -p "Exclude Patterns: " exclude_patterns
    exclude_patterns="${exclude_patterns:-wp-staging,*.log,cache,wpo-cache,wp-content/cache,wp-content/debug.log}"

    echo -e "${GREEN}Backup removal and cleanup settings for old files:${NC}"
    read -p "Main path (fullPath) for backup removal (default: $local_backup_dir): " full_path
    full_path="${full_path:-$local_backup_dir}"
    read -p "Retention (days to keep old backups) (default: 30): " retention
    retention="${retention:-30}"
    read -p "Log file max size for deletion in MB (default: 200): " max_log_size
    max_log_size="${max_log_size:-200}"
    let max_log_size_bytes=max_log_size*1024*1024
    read -p "Allowed archive extensions to clean-up (comma-separated, default: zip,tar,tar.gz,tgz,gz,bz2,xz,7z): " archive_exts
    archive_exts="${archive_exts:-zip,tar,tar.gz,tgz,gz,bz2,xz,7z}"
    read -p "Safe paths (comma-separated, default: $local_backup_dir,/var/backups,/home/backup): " safe_paths
    safe_paths="${safe_paths:-$local_backup_dir,/var/backups,/home/backup}"

    echo -e "${GREEN}Advanced backup cleanup options (disk space based deletion):${NC}"
    read -p "Enable disk free space cleanup? (y/n, default: n): " disk_free_enable
    disk_free_enable="${disk_free_enable:-n}"
    read -p "Minimum free disk space to keep in GB (ignored if not enabled, default: 20): " disk_min_free_gb
    disk_min_free_gb="${disk_min_free_gb:-20}"
    echo -e "${CYAN}Choose cleanup mode:${NC} [time] Only by retention, [space] Only disk free space, [both] Both (remove files older than retention only if disk free < minimum)"
    read -p "Cleanup mode [time|space|both] (default: time): " cleanup_mode
    cleanup_mode="${cleanup_mode:-time}"

    echo -e "${GREEN}Enter performance settings:${NC}"
    read -p "Nice Level (0-19, default: 19): " nice_level
    nice_level="${nice_level:-19}"

    echo -e "${GREEN}Enter notification settings:${NC}"
    read -p "Notification Methods (comma-separated: email,slack,telegram): " notify_method
    if [[ "$notify_method" == *"email"* ]]; then
        read -p "Email Address for Notifications: " notify_email
    fi
    if [[ "$notify_method" == *"slack"* ]]; then
        read -p "Slack Webhook URL: " slack_webhook
    fi
    if [[ "$notify_method" == *"telegram"* ]]; then
        read -p "Telegram Bot Token: " telegram_token
        read -p "Telegram Chat ID: " telegram_chat_id
    fi

    # Create the configuration file content using a heredoc
    cat > "$config_file" << EOF
# WordPress Backup Configuration File

# WordPress path
wpPath="$wp_path"

# Backup directory name format (supports date command)
DIR=${dir_name_fmt}

# Local backup directory
LOCAL_BACKUP_DIR="$local_backup_dir"

# Remote server SSH details
destinationUser="$ssh_user"
destinationIP="$ssh_ip"
destinationPort="$ssh_port"
destinationDbBackupPath="$db_path"
destinationFilesBackupPath="$files_path"
privateKeyPath="$key_path"

# Backup file prefixes
DB_FILE_PREFIX="$db_file_prefix"
FILES_FILE_PREFIX="$files_file_prefix"
COMPRESSION_FORMAT="$compression_format"

# Backup storage location (local, remote, both)
BACKUP_LOCATION="$backup_location"

# Performance settings
NICE_LEVEL="$nice_level"
EXCLUDE_PATTERNS="$exclude_patterns"
maxSize="$max_size"

# Notification settings
NOTIFY_METHOD="$notify_method"
NOTIFY_EMAIL="$notify_email"
SLACK_WEBHOOK_URL="$slack_webhook"
TELEGRAM_BOT_TOKEN="$telegram_token"
TELEGRAM_CHAT_ID="$telegram_chat_id"

# Backup removal settings
fullPath="$full_path"
BACKUP_RETAIN_DURATION=$retention
MAX_LOG_SIZE=$max_log_size_bytes
ARCHIVE_EXTS="$archive_exts"
SAFE_PATHS="$safe_paths"
DISK_FREE_ENABLE="$disk_free_enable"
DISK_MIN_FREE_GB="$disk_min_free_gb"
CLEANUP_MODE="$cleanup_mode"

EOF

    apply_config_permissions "$config_file"
    echo -e "${GREEN}${BOLD}Configuration file created: $config_file${NC}"
    echo -e "${YELLOW}${BOLD}SECURITY NOTICE:${NC} The config file permissions are set to 600 and root only; never share this file. Only use the unencrypted (.conf) file for cron jobs. Do NOT use encrypted (.gpg) configs in cron jobs!${NC}"

    read -p "Do you want to encrypt this configuration file? (y/n): " encrypt
    if [[ "$encrypt" == [yY] ]]; then
        encrypt_single_config "$config_file"
    fi
    return 0
}

# Encrypts one or all unencrypted (.conf) configuration files.
# Returns:
#   0 on success or if no files to encrypt, 1 on error (e.g., invalid selection, gpg missing).
encrypt_config() {
    echo -e "${BLUE}${BOLD}=== Encrypt Configuration Files ===${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    # Find unencrypted .conf files in the configs directory
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No unencrypted configuration files found!${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Select a configuration file to encrypt by number (or 'a' for all):${NC}"
    read -p "> " selection

    if [[ "$selection" == "a" || "$selection" == "A" ]]; then
        echo -e "${CYAN}Encrypting all configuration files...${NC}"
        for file in "${configs[@]}"; do
            encrypt_single_config "$file"
        done
    elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt ${#configs[@]} ]; then
        encrypt_single_config "${configs[$selection]}"
    else
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    return 0
}

# Encrypts a single specified configuration file using GPG.
# Arguments:
#   $1: Path to the configuration file to encrypt.
# Returns:
#   0 on successful encryption, 1 on failure or if GPG is not installed.
encrypt_single_config() {
    local config_file="$1"
    local config_name
    config_name=$(basename "$config_file")

    if ! command_exists gpg; then
        echo -e "${RED}${BOLD}Error: gpg is not installed. Cannot encrypt configuration files.${NC}" >&2
        echo -e "${YELLOW}Please install gpg and try again.${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}Encrypting ${config_name}...${NC}"
    gpg --symmetric --cipher-algo AES256 --output "${config_file}.gpg" "$config_file"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully encrypted ${config_name} to ${config_name}.gpg${NC}"
        read -p "Do you want to remove the unencrypted file? (y/n): " remove
        if [[ "$remove" == [yY] ]]; then
            rm -f "$config_file"
            echo -e "${GREEN}Removed unencrypted file: ${config_name}${NC}"
        fi
    else
        echo -e "${RED}${BOLD}Failed to encrypt ${config_name}!${NC}" >&2
        return 1
    fi
    return 0
}

# Decrypts one or all encrypted (.conf.gpg) configuration files.
# Returns:
#   0 on success or if no files to decrypt, 1 on error (e.g., invalid selection, gpg missing).
decrypt_config() {
    echo -e "${BLUE}${BOLD}=== Decrypt Configuration Files ===${NC}"
    echo -e "${GREEN}Available encrypted configuration files:${NC}"
    encrypted_configs=()
    i=0
    # Find .conf.gpg files in the configs directory
    while IFS= read -r file; do
        encrypted_configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file")${NC}"
        ((i++))
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf.gpg" | sort)

    if [ ${#encrypted_configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No encrypted configuration files found!${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Select a configuration file to decrypt by number (or 'a' for all):${NC}"
    read -p "> " selection

    if [[ "$selection" == "a" || "$selection" == "A" ]]; then
        echo -e "${CYAN}Decrypting all configuration files...${NC}"
        for file in "${encrypted_configs[@]}"; do
            decrypt_single_config "$file"
        done
    elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt ${#encrypted_configs[@]} ]; then
        decrypt_single_config "${encrypted_configs[$selection]}"
    else
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    return 0
}

# Decrypts a single specified GPG-encrypted configuration file.
# Arguments:
#   $1: Path to the encrypted (.gpg) file.
# Returns:
#   0 on successful decryption or if aborted by user, 1 on failure or if GPG is missing.
decrypt_single_config() {
    local encrypted_file="$1"
    local decrypted_file="${encrypted_file%.gpg}" # Remove .gpg extension
    local file_name
    file_name=$(basename "$encrypted_file")

    if ! command_exists gpg; then
        echo -e "${RED}${BOLD}Error: gpg is not installed. Cannot decrypt configuration files.${NC}" >&2
        echo -e "${YELLOW}Please install gpg and try again.${NC}" >&2
        return 1
    fi

    if [ -f "$decrypted_file" ]; then
        echo -e "${YELLOW}${BOLD}Warning: Unencrypted file already exists: $(basename "$decrypted_file")${NC}"
        read -p "Do you want to overwrite it? (y/n): " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo -e "${YELLOW}Decryption aborted.${NC}"
            return 0
        fi
    fi

    echo -e "${CYAN}Decrypting ${file_name}...${NC}"
    gpg --quiet --decrypt --output "$decrypted_file" "$encrypted_file"

    if [ $? -eq 0 ]; then
        apply_config_permissions "$decrypted_file"
        echo -e "${GREEN}Successfully decrypted to $(basename "$decrypted_file") and permissions set to 600/root.${NC}"
        read -p "Do you want to remove the encrypted file? (y/n): " remove
        if [[ "$remove" == [yY] ]]; then
            rm -f "$encrypted_file"
            echo -e "${GREEN}Removed encrypted file: ${file_name}${NC}"
        fi
        echo -e "${YELLOW}SECURITY NOTICE: Only use this decrypted (.conf) file for jobs/cron, never .gpg files! File is root:600.${NC}"
    else
        echo -e "${RED}${BOLD}Failed to decrypt ${file_name}!${NC}" >&2
        return 1
    fi
    return 0
}

# Tests a selected configuration file for required variables.
# Loads and validates the configuration (decrypts if necessary).
# Returns:
#   0 if configuration is valid, 1 otherwise (e.g., file not found, decryption failed, missing variables).
test_config() {
    echo -e "${BLUE}${BOLD}=== Test Configuration File ===${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    # List unencrypted .conf files
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
    # List encrypted .conf.gpg files
    while IFS= read -r file; do
        configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}"
        ((i++))
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf.gpg" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No configuration files found!${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Select a configuration file to test by number:${NC}"
    read -p "> " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    CONFIG_FILE="${configs[$selection]}"
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    # Load the configuration file (decrypt if necessary)
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            return 1
        fi
        echo -e "${CYAN}Loading encrypted configuration file...${NC}"
        # Source the decrypted output of gpg
        eval "$(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2
            return 1
        fi
    else
        echo -e "${CYAN}Loading configuration file...${NC}"
        source "$CONFIG_FILE" # Source the unencrypted file
    fi

    echo -e "${CYAN}Testing configuration variables...${NC}"
    local missing_vars=()
    # List of required variables to check
    for var in wpPath destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then # Check if variable is empty
            missing_vars+=("$var")
        else
            echo -e "${GREEN}✓ $var: ${!var}${NC}"
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo -e "${RED}${BOLD}Error: Missing required variables: ${missing_vars[*]}${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}${BOLD}Configuration file validated successfully!${NC}"
    return 0
}

# Sets up cron jobs for automated backups based on user input.
# Allows selection of config file, schedule, backup type, and other options.
# Returns:
#   0 on success or if skipped by user, 1 on error.
setup_cron() {
    echo -e "${CYAN}${BOLD}Setting up cron jobs...${NC}"
    read -p "Do you want to set up automated backups via cron? (y/n): " setup
    if [[ "$setup" != [yY] ]]; then
        echo -e "${YELLOW}Cron setup skipped.${NC}"
        return 0
    fi

    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    # List unencrypted .conf files
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
    # List encrypted .conf.gpg files
    while IFS= read -r file; do
        configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}"
        ((i++))
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf.gpg" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No configuration files found!${NC}" >&2
        echo -e "${YELLOW}Please create a configuration file first.${NC}"
        return 1
    fi

    echo -e "${GREEN}Select a configuration file by number:${NC}"
    read -p "> " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    CONFIG_FILE="${configs[$selection]}"
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        echo -e "${RED}${BOLD}ERROR: You cannot use an encrypted config (.gpg) file in a cron job!${NC}"
        echo -e "${YELLOW}Please decrypt the config file first and use the decrypted .conf (with 600 mode, root ownership only).${NC}"
        return 1
    fi

    apply_config_permissions "$CONFIG_FILE"
    local CRON_CMD="crontab" # Default to user's crontab
    if [ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)" == "root" ] && [ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)" == "600" ]; then
        CRON_CMD="sudo crontab"
        echo -e "${YELLOW}The cron job will be installed for root as the config file is only readable by root!${NC}"
    else
        if ! [ -r "$CONFIG_FILE" ]; then
             echo -e "${RED}${BOLD}Error: The current user cannot read the selected configuration file: $(basename "$CONFIG_FILE")${NC}" >&2
             echo -e "${YELLOW}Ensure the file has appropriate read permissions for the user running this script, or run as a user with access.${NC}" >&2
             return 1
        fi
        echo -e "${YELLOW}WARNING: The config file is not root:root with 600 permissions. Ensure only privileged users can read it if it contains sensitive data.${NC}"
        echo -e "${YELLOW}The cron job will be installed for the current user: $(whoami)${NC}"
    fi

    echo -e "${GREEN}Choose backup schedule:${NC}"
    echo "[1] Daily"
    echo "[2] Weekly"
    echo "[3] Monthly"
    echo "[4] Every 12 hours"
    echo "[5] Every 6 hours"
    echo "[6] Every 4 hours"
    echo "[7] Custom"
    read -p "> " schedule_option

    local cron_time=""
    local schedule_desc=""

    case $schedule_option in
    1) # Daily
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour * * *"
        schedule_desc="daily at $hour:$minute"
        ;;
    2) # Weekly
        read -p "Enter day of week (0-6, where 0=Sunday, default: 0): " day_of_week
        day_of_week="${day_of_week:-0}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour * * $day_of_week"
        local day_name
        case $day_of_week in
            0) day_name="Sunday";; 1) day_name="Monday";; 2) day_name="Tuesday";;
            3) day_name="Wednesday";; 4) day_name="Thursday";; 5) day_name="Friday";;
            6) day_name="Saturday";; *) day_name="Day $day_of_week";;
        esac
        schedule_desc="weekly on $day_name at $hour:$minute"
        ;;
    3) # Monthly
        read -p "Enter day of month (1-31, default: 1): " day_of_month
        day_of_month="${day_of_month:-1}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour $day_of_month * *"
        schedule_desc="monthly on day $day_of_month at $hour:$minute"
        ;;
    4) # Every 12 hours
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute */12 * * *"
        schedule_desc="every 12 hours at minute $minute"
        ;;
    5) # Every 6 hours
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute */6 * * *"
        schedule_desc="every 6 hours at minute $minute"
        ;;
    6) # Every 4 hours
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute */4 * * *"
        schedule_desc="every 4 hours at minute $minute"
        ;;
    7) # Custom
        read -p "Enter custom cron schedule (e.g., '0 2 * * 0'): " cron_time
        if [ -z "$cron_time" ]; then
            echo -e "${RED}${BOLD}Error: Custom cron schedule cannot be empty!${NC}" >&2
            return 1
        fi
        schedule_desc="custom schedule: $cron_time"
        ;;
    *) # Invalid option
        echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
        return 1
        ;;
    esac

    echo -e "${GREEN}Choose backup type:${NC}"
    echo "[1] Full backup (database + files)"
    echo "[2] Database only"
    echo "[3] Files only"
    read -p "> " backup_type

    local backup_script_name=""
    local backup_desc=""

    case $backup_type in
    1) # Full backup
        backup_script_name="backup.sh"
        backup_desc="full backup"
        ;;
    2) # Database only
        backup_script_name="database.sh"
        backup_desc="database backup"
        ;;
    3) # Files only
        backup_script_name="files.sh"
        backup_desc="files backup"
        ;;
    *) # Invalid option
        echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
        return 1
        ;;
    esac
    
    # Ensure the chosen backup script exists and is executable
    if [ ! -x "$SCRIPTPATH/$backup_script_name" ]; then
        echo -e "${RED}${BOLD}Error: Backup script '$SCRIPTPATH/$backup_script_name' not found or not executable.${NC}" >&2
        echo -e "${YELLOW}Please ensure it exists and run 'Set file permissions for scripts' from the main menu.${NC}" >&2
        return 1
    fi

    read -p "Do you want to use incremental backup for files (if applicable to $backup_script_name)? (y/n, default: n): " incremental
    local incremental_flag=""
    if [[ "$incremental" == [yY] ]]; then
        incremental_flag="-i"
        backup_desc="$backup_desc (incremental)"
    fi

    read -p "Do you want to store backups both locally and remotely? (y/n, default: y based on config): " store_both
    local location_flag_input=""
    if [[ "$store_both" == [yY] || "$store_both" == "" ]]; then
        location_flag_input="-b" # Explicitly set both for cron
        echo -e "${CYAN}Cron will attempt to use both local and remote storage.${NC}"
    elif [[ "$store_both" == [nN] ]]; then
        read -p "Store locally only? (y/n, default: n, meaning remote only if not local): " local_only
        if [[ "$local_only" == [yY] ]]; then
            location_flag_input="-l"
             echo -e "${CYAN}Cron will attempt to use local storage only.${NC}"
        else
            location_flag_input="-r"
             echo -e "${CYAN}Cron will attempt to use remote storage only.${NC}"
        fi
    fi
    
    # Construct the cron command, redirecting output to /dev/null
    local cron_job_command="$cron_time cd \"$SCRIPTPATH\" && ./$backup_script_name -c \"$CONFIG_FILE\" -q $incremental_flag $location_flag_input > /dev/null 2>&1"
    
    # Pattern to identify and remove existing cron job for this specific script and config
    local pattern_to_remove="$backup_script_name -c \"$CONFIG_FILE\""

    # Add or update the cron job
    ( $CRON_CMD -l 2>/dev/null || echo "" ) | \
    grep -vF "$pattern_to_remove" | \
    { cat; echo "$cron_job_command"; } | \
    $CRON_CMD -

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}Cron job for $backup_script_name with $(basename "$CONFIG_FILE") added/updated successfully!${NC}"
        echo -e "${GREEN}Schedule:${NC} $schedule_desc"
        echo -e "${GREEN}Backup type:${NC} $backup_desc"
        echo -e "${GREEN}Full command:${NC} $cron_job_command"
        echo -e "${CYAN}Verifying cron job (listing relevant entries for $USER)...${NC}"
        $CRON_CMD -l | grep -F --color=auto "$pattern_to_remove" || echo -e "${YELLOW}Could not verify or no matching cron job found for current user/root.${NC}"
    else
        echo -e "${RED}${BOLD}Error: Failed to add/update cron job!${NC}" >&2
        return 1
    fi
    return 0
}

# Tests SSH connection to a remote server using details from a configuration file.
# Also checks for existence of remote backup directories and offers to create them.
# Returns:
#   0 on successful connection and directory checks, 1 on failure.
test_ssh_connection() {
    echo -e "${CYAN}${BOLD}Testing SSH connection...${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    # List unencrypted .conf files
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
    # List encrypted .conf.gpg files
    while IFS= read -r file; do
        configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}"
        ((i++))
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf.gpg" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No configuration files found!${NC}" >&2
        echo -e "${YELLOW}Please create a configuration file first.${NC}"
        return 1
    fi

    echo -e "${GREEN}Select a configuration file by number:${NC}"
    read -p "> " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    CONFIG_FILE="${configs[$selection]}"
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    # Load configuration (decrypt if needed)
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            return 1
        fi
        eval "$(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)" # Source decrypted output
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2
            return 1
        fi
    else
        source "$CONFIG_FILE" # Source unencrypted file
    fi

    # Check for required SSH variables in the config
    for var in destinationPort destinationUser destinationIP privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in the configuration file!${NC}" >&2
            return 1
        fi
    done

    echo -e "${CYAN}Testing SSH connection to ${destinationUser}@${destinationIP}:${destinationPort}...${NC}"
    # Attempt SSH connection with a timeout and execute a simple echo command
    ssh -p "${destinationPort}" -i "${privateKeyPath}" -o ConnectTimeout=10 "${destinationUser}@${destinationIP}" "echo 'SSH connection successful!'" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}SSH connection successful!${NC}"
        # Check if remote backup directories exist
        for var in destinationDbBackupPath destinationFilesBackupPath; do
            if [ -n "${!var}" ]; then
                echo -e "${CYAN}Testing if remote directory ${!var} exists...${NC}"
                if ssh -p "${destinationPort}" -i "${privateKeyPath}" "${destinationUser}@${destinationIP}" "[ -d \"${!var}\" ]" 2>/dev/null; then
                    echo -e "${GREEN}Remote directory ${!var} exists.${NC}"
                else
                    echo -e "${YELLOW}Remote directory ${!var} does not exist.${NC}"
                    read -p "Do you want to create it? (y/n): " create_dir
                    if [[ "$create_dir" == [yY] ]]; then
                        ssh -p "${destinationPort}" -i "${privateKeyPath}" "${destinationUser}@${destinationIP}" "mkdir -p \"${!var}\"" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}Remote directory ${!var} created successfully.${NC}"
                        else
                            echo -e "${RED}${BOLD}Failed to create remote directory ${!var}!${NC}" >&2
                        fi
                    fi
                fi
            fi
        done
    else
        echo -e "${RED}${BOLD}SSH connection failed!${NC}" >&2
        echo -e "${YELLOW}Please check your SSH settings in the configuration file.${NC}"
        return 1
    fi
    return 0
}

# Sets up a cron job for the backup cleanup script (removeOld.sh).
# Allows selection of config file and schedule.
# Returns:
#   0 on success, 1 on error.
setup_cleanup_cron() {
    echo -e "${CYAN}${BOLD}Setting up cron job for backup cleanup (remove old backups/logs)...${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"

    configs=()
    i=0
    # List unencrypted .conf files
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
    # List encrypted .conf.gpg files
    while IFS= read -r file; do
        configs+=("$file")
        echo -e "[$i] ${PURPLE}$(basename "$file") (encrypted)${NC}"
        ((i++))
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf.gpg" | sort)

    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}Error: No configuration files found!${NC}" >&2
        echo -e "${YELLOW}Please create a configuration file first.${NC}"
        return 1
    fi

    echo -e "${GREEN}Select a configuration file by number:${NC}"
    read -p "> " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge ${#configs[@]} ]; then
        echo -e "${RED}${BOLD}Error: Invalid selection!${NC}" >&2
        return 1
    fi
    CONFIG_FILE="${configs[$selection]}"
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        echo -e "${YELLOW}Warning: Running removeOld.sh with an encrypted .gpg config. Ensure the passphrase is available if needed.${NC}"
    fi

    echo -e "${GREEN}Choose cleanup schedule:${NC}"
    echo "[1] Daily"
    echo "[2] Weekly"
    echo "[3] Monthly"
    echo "[4] Custom"
    read -p "> " schedule_option

    local cron_time=""
    local schedule_desc=""

    case $schedule_option in
    1) # Daily
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 15): " minute
        minute="${minute:-15}"
        cron_time="$minute $hour * * *"
        schedule_desc="daily at $hour:$minute"
        ;;
    2) # Weekly
        read -p "Enter day of week (0-6, where 0=Sunday, default: 0): " day_of_week
        day_of_week="${day_of_week:-0}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 15): " minute
        minute="${minute:-15}"
        cron_time="$minute $hour * * $day_of_week"
        local day_name
        case $day_of_week in
            0) day_name="Sunday";; 1) day_name="Monday";; 2) day_name="Tuesday";;
            3) day_name="Wednesday";; 4) day_name="Thursday";; 5) day_name="Friday";;
            6) day_name="Saturday";; *) day_name="Day $day_of_week";;
        esac
        schedule_desc="weekly on $day_name at $hour:$minute"
        ;;
    3) # Monthly
        read -p "Enter day of month (1-31, default: 1): " day_of_month
        day_of_month="${day_of_month:-1}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 15): " minute
        minute="${minute:-15}"
        cron_time="$minute $hour $day_of_month * *"
        schedule_desc="monthly on day $day_of_month at $hour:$minute"
        ;;
    4) # Custom
        read -p "Enter custom cron schedule (e.g., '15 2 * * 0'): " cron_time
        if [ -z "$cron_time" ]; then
            echo -e "${RED}${BOLD}Error: Custom cron schedule cannot be empty!${NC}" >&2
            return 1
        fi
        schedule_desc="custom schedule: $cron_time"
        ;;
    *) # Invalid option
        echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
        return 1
        ;;
    esac

    read -p "Add with dry-run for test? (y/n, default: n): " dry
    local dry_flag=""
    if [[ "$dry" == [yY] ]]; then
        dry_flag="-d" # Add dry-run flag if chosen
        schedule_desc="$schedule_desc (dry-run)"
    fi

    apply_config_permissions "$CONFIG_FILE" # Ensure config file has secure permissions
    local CRON_CMD="crontab" # Default to user's crontab
    if [ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)" == "root" ] && [ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)" == "600" ]; then
        CRON_CMD="sudo crontab"
        echo -e "${YELLOW}The cron job will be installed for root as the config file is only readable by root!${NC}"
    else
        if ! [ -r "$CONFIG_FILE" ]; then # Check if current user can read config
             echo -e "${RED}${BOLD}Error: Current user cannot read $CONFIG_FILE. Adjust permissions or run as owner/root.${NC}" >&2
             return 1
        fi
        echo -e "${YELLOW}WARNING: The config file is not root 600; ensure only privileged users can read.${NC}"
        echo -e "${YELLOW}The cron job will be installed for the current user: $(whoami)${NC}"
    fi

    # Construct the cron command for removeOld.sh
    local cron_job_command="$cron_time cd \"$SCRIPTPATH\" && ./removeOld.sh -c \"$CONFIG_FILE\" $dry_flag > /dev/null 2>&1"

    # Add or update the cleanup cron job, ensuring not to duplicate it
    ( $CRON_CMD -l 2>/dev/null || echo "" ) | grep -vF "removeOld.sh -c \"$CONFIG_FILE\"" | { cat; echo "$cron_job_command"; } | $CRON_CMD -

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}Cleanup cron job added successfully!${NC}"
        echo -e "${GREEN}Schedule:${NC} $schedule_desc"
        echo -e "${GREEN}Configuration:${NC} $(basename "$CONFIG_FILE")"
    else
        echo -e "${RED}${BOLD}Error: Failed to add cleanup cron job!${NC}" >&2
        return 1
    fi
    return 0
}

# --- Main Menu Function ---
# Displays the main interactive menu for the backup system setup.
show_menu() {
    clear
    echo -e "${BLUE}${BOLD}=== WordPress Backup System Setup ===${NC}"
    echo -e "${CYAN}1. Create directory structure${NC}"
    echo -e "${CYAN}2. Create new configuration${NC}"
    echo -e "${CYAN}3. Set up cron jobs for backups${NC}"
    echo -e "${CYAN}4. Test SSH connection${NC}"
    echo -e "${CYAN}5. Set file permissions for scripts${NC}"
    echo -e "${CYAN}6. Encrypt configuration file${NC}"
    echo -e "${CYAN}7. Decrypt configuration file${NC}"
    echo -e "${CYAN}8. Test configuration file${NC}"
    echo -e "${CYAN}9. Set up cron job for cleanup (Remove old backups/logs)${NC}"
    echo -e "${CYAN}0. Exit${NC}"
    echo
    read -p "Enter your choice: " choice
    case $choice in
    1) # Create directory structure
        echo -e "${BLUE}${BOLD}=== Creating Directory Structure ===${NC}"
        create_directory "$SCRIPTPATH/configs"
        create_directory "$SCRIPTPATH/backups"      # General/temporary backup directory
        create_directory "$SCRIPTPATH/local_backups" # Specific for local backup storage
        create_directory "$SCRIPTPATH/logs"
        echo -e "${GREEN}${BOLD}Directory structure created successfully!${NC}"
        read -p "Press Enter to continue..."
        ;;
    2) # Create new configuration
        echo -e "${BLUE}${BOLD}=== Creating New Configuration ===${NC}"
        read -p "Enter configuration name (e.g., mywordpress_site): " config_input
        if [ -z "$config_input" ]; then
             echo -e "${RED}Configuration name cannot be empty.${NC}"
        else
            create_config "$config_input"
        fi
        read -p "Press Enter to continue..."
        ;;
    3) # Setup backup cron jobs
        setup_cron
        read -p "Press Enter to continue..."
        ;;
    4) # Test SSH connection
        test_ssh_connection
        read -p "Press Enter to continue..."
        ;;
    5) # Set script permissions
        echo -e "${BLUE}${BOLD}=== Setting File Permissions ===${NC}"
        set_permissions "$SCRIPTPATH/database.sh" "755"   # Assumed DB backup script
        set_permissions "$SCRIPTPATH/files.sh" "755"      # Assumed files backup script
        set_permissions "$SCRIPTPATH/backup.sh" "755"     # Assumed combined backup script
        set_permissions "$SCRIPTPATH/setup.sh" "755"      # This setup script
        set_permissions "$SCRIPTPATH/removeOld.sh" "755"  # Assumed cleanup script
        set_permissions "$SCRIPTPATH/common.sh" "644"     # Assumed common functions script
        echo -e "${GREEN}${BOLD}File permissions set successfully!${NC}"
        read -p "Press Enter to continue..."
        ;;
    6) # Encrypt configuration
        encrypt_config
        read -p "Press Enter to continue..."
        ;;
    7) # Decrypt configuration
        decrypt_config
        read -p "Press Enter to continue..."
        ;;
    8) # Test configuration
        test_config
        read -p "Press Enter to continue..."
        ;;
    9) # Setup cleanup cron job
        setup_cleanup_cron
        read -p "Press Enter to continue..."
        ;;
    0) # Exit
        echo -e "${GREEN}${BOLD}Exiting setup. Goodbye!${NC}"
        exit 0
        ;;
    *) # Invalid choice
        echo -e "${RED}${BOLD}Invalid choice!${NC}"
        read -p "Press Enter to continue..."
        ;;
    esac
}

# --- Script Execution ---

# Check for essential commands required by the script and its sub-operations.
REQUIRED_COMMANDS=(
    "ssh" "rsync" "gpg" "tar" "gzip" "bzip2" "xz" "zip" "unzip"
    "stat" "date" "crontab" "mkdir" "chmod" "cat" "grep" "find" "basename" "dirname" "sudo"
)
check_requirements "${REQUIRED_COMMANDS[@]}" || {
    echo -e "${RED}${BOLD}Please install all required packages and run the script again.${NC}" >&2
    exit 1
}

# Main loop to continuously display the menu until the user exits.
while true; do
    show_menu
done