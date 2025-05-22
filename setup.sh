#!/bin/bash
# setup.sh -- Secure, robust, full-featured setup for WordPress backup scripting
# Language/UX: FULL ENGLISH
# Security: Config files access 600, root ownership, enforces decrypted config for cron
# All original BASH functions and menu intact; improved error/user guidance

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

apply_config_permissions() {
    local config_file="$1"
    chmod 600 "$config_file"
    if command_exists chown; then
        sudo chown root:root "$config_file" 2>/dev/null || true
    fi
    if [ $(stat -c "%a" "$config_file") != "600" ]; then
        echo -e "${YELLOW}Warning: Could not set file mode 600 on $config_file${NC}"
    fi
}

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

create_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo -e "${CYAN}Creating directory: $dir${NC}"
        mkdir -p "$dir"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to create directory $dir${NC}" >&2
            return 1
        fi
    else
        echo -e "${GREEN}Directory already exists: $dir${NC}"
    fi
    return 0
}

set_permissions() {
    local path="$1"
    local perms="$2"
    echo -e "${CYAN}Setting permissions $perms on $path${NC}"
    chmod -R "$perms" "$path"
    if [ $? -ne 0 ]; then
        echo -e "${RED}${BOLD}Error: Failed to set permissions on $path${NC}" >&2
        return 1
    fi
    return 0
}

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

    cat > "$config_file" << EOF
wpPath="$wp_path"
DIR=${dir_name_fmt}
LOCAL_BACKUP_DIR="$local_backup_dir"
destinationUser="$ssh_user"
destinationIP="$ssh_ip"
destinationPort="$ssh_port"
destinationDbBackupPath="$db_path"
destinationFilesBackupPath="$files_path"
privateKeyPath="$key_path"
DB_FILE_PREFIX="$db_file_prefix"
FILES_FILE_PREFIX="$files_file_prefix"
COMPRESSION_FORMAT="$compression_format"
BACKUP_LOCATION="$backup_location"
NICE_LEVEL="$nice_level"
EXCLUDE_PATTERNS="$exclude_patterns"
maxSize="$max_size"
NOTIFY_METHOD="$notify_method"
NOTIFY_EMAIL="$notify_email"
SLACK_WEBHOOK_URL="$slack_webhook"
TELEGRAM_BOT_TOKEN="$telegram_token"
TELEGRAM_CHAT_ID="$telegram_chat_id"
fullPath="$full_path"
BACKUP_RETAIN_DURATION=$retention
MAX_LOG_SIZE=$max_log_size_bytes
ARCHIVE_EXTS="$archive_exts"
SAFE_PATHS="$safe_paths"
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

encrypt_config() {
    echo -e "${BLUE}${BOLD}=== Encrypt Configuration Files ===${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
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

encrypt_single_config() {
    local config_file="$1"
    local config_name=$(basename "$config_file")
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

decrypt_config() {
    echo -e "${BLUE}${BOLD}=== Decrypt Configuration Files ===${NC}"
    echo -e "${GREEN}Available encrypted configuration files:${NC}"
    encrypted_configs=()
    i=0
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

decrypt_single_config() {
    local encrypted_file="$1"
    local decrypted_file="${encrypted_file%.gpg}"
    local file_name=$(basename "$encrypted_file")
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

test_config() {
    echo -e "${BLUE}${BOLD}=== Test Configuration File ===${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
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
    # Load and test the configuration file
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            return 1
        fi
        echo -e "${CYAN}Loading encrypted configuration file...${NC}"
        eval "$(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2
            return 1
        fi
    else
        echo -e "${CYAN}Loading configuration file...${NC}"
        source "$CONFIG_FILE"
    fi
    echo -e "${CYAN}Testing configuration variables...${NC}"
    local missing_vars=()
    for var in wpPath destinationPort destinationUser destinationIP destinationDbBackupPath destinationFilesBackupPath privateKeyPath; do
        if [ -z "${!var}" ]; then
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
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
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
    config_name=$(basename "$CONFIG_FILE" | sed 's/\..*//')
    echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

    # If .gpg, strongly forbid usage for cron for security
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        echo -e "${RED}${BOLD}ERROR: You cannot use an encrypted config (.gpg) file in a cron job!${NC}"
        echo -e "${YELLOW}Please decrypt the config file first and use the decrypted .conf (with 600 mode, root ownership only).${NC}"
        return 1
    fi

    # Ensure only root can read the config for cron execution
    apply_config_permissions "$CONFIG_FILE"
    if [ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)" == "root" ] && [ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)" == "600" ]; then
        CRON="sudo crontab"
        echo -e "${YELLOW}The cron job will be installed for root as the config file is only readable by root!${NC}"
    else
        CRON="crontab"
        echo -e "${YELLOW}WARNING: The config file is not root 600; ensure only privileged users can read.${NC}"
    fi

    echo -e "${GREEN}Choose backup schedule:${NC}"
    echo -e "[1] Daily"
    echo -e "[2] Weekly"
    echo -e "[3] Monthly"
    echo -e "[4] Custom"
    read -p "> " schedule_option

    case $schedule_option in
    1)
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour * * *"
        schedule_desc="daily at $hour:$minute"
        ;;
    2)
        read -p "Enter day of week (0-6, where 0=Sunday, default: 0): " day_of_week
        day_of_week="${day_of_week:-0}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour * * $day_of_week"
        case $day_of_week in
            0) day_name="Sunday";;
            1) day_name="Monday";;
            2) day_name="Tuesday";;
            3) day_name="Wednesday";;
            4) day_name="Thursday";;
            5) day_name="Friday";;
            6) day_name="Saturday";;
        esac
        schedule_desc="weekly on $day_name at $hour:$minute"
        ;;
    3)
        read -p "Enter day of month (1-31, default: 1): " day_of_month
        day_of_month="${day_of_month:-1}"
        read -p "Enter hour (0-23, default: 2): " hour
        hour="${hour:-2}"
        read -p "Enter minute (0-59, default: 0): " minute
        minute="${minute:-0}"
        cron_time="$minute $hour $day_of_month * *"
        schedule_desc="monthly on day $day_of_month at $hour:$minute"
        ;;
    4)
        read -p "Enter custom cron schedule (e.g., '0 2 * * 0'): " cron_time
        schedule_desc="custom schedule: $cron_time"
        ;;
    *)
        echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
        return 1
        ;;
esac

echo -e "${GREEN}Choose backup type:${NC}"
echo -e "[1] Full backup (database + files)"
echo -e "[2] Database only"
echo -e "[3] Files only"
read -p "> " backup_type

case $backup_type in
    1)
        backup_script="backup.sh"
        backup_desc="full backup"
        ;;
    2)
        backup_script="database.sh"
        backup_desc="database backup"
        ;;
    3)
        backup_script="files.sh"
        backup_desc="files backup"
        ;;
    *)
        echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
        return 1
        ;;
esac

read -p "Do you want to use incremental backup for files? (y/n, default: n): " incremental
incremental_flag=""
if [[ "$incremental" == [yY] ]]; then
    incremental_flag="-i"
    backup_desc="$backup_desc (incremental)"
fi

read -p "Do you want to store backups both locally and remotely? (y/n, default: y): " both_locations
location_flag="-b"
if [[ "$both_locations" != [yY] && "$both_locations" != "" ]]; then
    read -p "Store locally only? (y/n, default: n): " local_only
    if [[ "$local_only" == [yY] ]]; then
        location_flag="-l"
    else
        location_flag="-r"
    fi
fi

cron_command="$cron_time cd $SCRIPTPATH && ./$(basename "$backup_script") -c \"$CONFIG_FILE\" $incremental_flag $location_flag > /dev/null 2>&1"

(crontab -l 2>/dev/null || echo "") | grep -v "$(basename "$backup_script") -c \"$CONFIG_FILE\"" | { cat; echo "$cron_command"; } | $CRON -

if [ $? -eq 0 ]; then
    echo -e "${GREEN}${BOLD}Cron job added successfully!${NC}"
    echo -e "${GREEN}Schedule: ${NC}$schedule_desc"
    echo -e "${GREEN}Backup type: ${NC}$backup_desc"
    echo -e "${GREEN}Configuration: ${NC}$(basename "$CONFIG_FILE")"
else
    echo -e "${RED}${BOLD}Error: Failed to add cron job!${NC}" >&2
    return 1
fi
return 0
}

test_ssh_connection() {
    echo -e "${CYAN}${BOLD}Testing SSH connection...${NC}"
    echo -e "${GREEN}Available configuration files:${NC}"
    configs=()
    i=0
    while IFS= read -r file; do
        if [[ "$file" != *".gpg" ]]; then
            configs+=("$file")
            echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
            ((i++))
        fi
    done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
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
        if ! command_exists gpg; then
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            return 1
        fi
        eval "$(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to decrypt configuration file!${NC}" >&2
            return 1
        fi
    else
        source "$CONFIG_FILE"
    fi
    for var in destinationPort destinationUser destinationIP privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in the configuration file!${NC}" >&2
            return 1
        fi
    done
    echo -e "${CYAN}Testing SSH connection to ${destinationUser}@${destinationIP}:${destinationPort}...${NC}"
    ssh -p "${destinationPort}" -i "${privateKeyPath}" -o ConnectTimeout=10 "${destinationUser}@${destinationIP}" "echo 'SSH connection successful!'" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}SSH connection successful!${NC}"
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

show_menu() {
    clear
    echo -e "${BLUE}${BOLD}=== WordPress Backup System Setup ===${NC}"
    echo -e "${CYAN}1. Create directory structure${NC}"
    echo -e "${CYAN}2. Create new configuration${NC}"
    echo -e "${CYAN}3. Set up cron jobs${NC}"
    echo -e "${CYAN}4. Test SSH connection${NC}"
    echo -e "${CYAN}5. Set file permissions${NC}"
    echo -e "${CYAN}6. Encrypt configuration file${NC}"
    echo -e "${CYAN}7. Decrypt configuration file${NC}"
    echo -e "${CYAN}8. Test configuration file${NC}"
    echo -e "${CYAN}9. Set up cleanup cron job (Remove old backups/logs)${NC}"
    echo -e "${CYAN}0. Exit${NC}"
    echo
    read -p "Enter your choice: " choice
    case $choice in
    1)
        echo -e "${BLUE}${BOLD}=== Creating Directory Structure ===${NC}"
        create_directory "$SCRIPTPATH/configs"
        create_directory "$SCRIPTPATH/backups"
        create_directory "$SCRIPTPATH/local_backups"
        create_directory "$SCRIPTPATH/logs"
        echo -e "${GREEN}${BOLD}Directory structure created successfully!${NC}"
        read -p "Press Enter to continue..."
        ;;
    2)
        echo -e "${BLUE}${BOLD}=== Creating New Configuration ===${NC}"
        read -p "Enter configuration name: " config
        create_config "$config"
        read -p "Press Enter to continue..."
        ;;
    3)
        setup_cron
        read -p "Press Enter to continue..."
        ;;
    4)
        test_ssh_connection
        read -p "Press Enter to continue..."
        ;;
    5)
        echo -e "${BLUE}${BOLD}=== Setting File Permissions ===${NC}"
        set_permissions "$SCRIPTPATH/database.sh" "755"
        set_permissions "$SCRIPTPATH/files.sh" "755"
        set_permissions "$SCRIPTPATH/backup.sh" "755"
        set_permissions "$SCRIPTPATH/setup.sh" "755"
        set_permissions "$SCRIPTPATH/common.sh" "644"
        echo -e "${GREEN}${BOLD}File permissions set successfully!${NC}"
        read -p "Press Enter to continue..."
        ;;
    6)
        encrypt_config
        read -p "Press Enter to continue..."
        ;;
    7)
        decrypt_config
        read -p "Press Enter to continue..."
        ;;
    8)
        test_config
        read -p "Press Enter to continue..."
        ;;
    9)
        setup_cleanup_cron
        read -p "Press Enter to continue..."
        ;;
    0)
        echo -e "${GREEN}${BOLD}Exiting setup. Goodbye!${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}${BOLD}Invalid choice!${NC}"
        read -p "Press Enter to continue..."
        ;;
    esac
}

check_requirements "ssh" "rsync" || {
    echo -e "${RED}${BOLD}Please install the required packages and run the script again.${NC}" >&2
    exit 1
}

setup_cleanup_cron() {
  echo -e "${CYAN}${BOLD}Setting up cron job for backup cleanup (remove old backups/logs)...${NC}"
  echo -e "${GREEN}Available configuration files:${NC}"

  configs=()
  i=0
  while IFS= read -r file; do
    if [[ "$file" != *".gpg" ]]; then
      configs+=("$file")
      echo -e "[$i] ${CYAN}$(basename "$file")${NC}"
      ((i++))
    fi
  done < <(find "$SCRIPTPATH/configs" -type f -name "*.conf" | sort)
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
  config_name=$(basename "$CONFIG_FILE" | sed 's/\..*//')
  echo -e "${GREEN}Selected: ${BOLD}$(basename "$CONFIG_FILE")${NC}"

  if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
    echo -e "${YELLOW}Warning: Running removeOld.sh with an encrypted .gpg config. اطمینان حاصل کنید که رمز صحیح در دسترس است.${NC}"
  fi

  echo -e "${GREEN}Choose cleanup schedule:${NC}"
  echo -e "[1] Daily"
  echo -e "[2] Weekly"
  echo -e "[3] Monthly"
  echo -e "[4] Custom"
  read -p "> " schedule_option

  case $schedule_option in
    1)
      read -p "Enter hour (0-23, default: 2): " hour
      hour="${hour:-2}"
      read -p "Enter minute (0-59, default: 15): " minute
      minute="${minute:-15}"
      cron_time="$minute $hour * * *"
      schedule_desc="daily at $hour:$minute"
      ;;
    2)
      read -p "Enter day of week (0-6, where 0=Sunday, default: 0): " day_of_week
      day_of_week="${day_of_week:-0}"
      read -p "Enter hour (0-23, default: 2): " hour
      hour="${hour:-2}"
      read -p "Enter minute (0-59, default: 15): " minute
      minute="${minute:-15}"
      cron_time="$minute $hour * * $day_of_week"
      case $day_of_week in
        0) day_name="Sunday";;
        1) day_name="Monday";;
        2) day_name="Tuesday";;
        3) day_name="Wednesday";;
        4) day_name="Thursday";;
        5) day_name="Friday";;
        6) day_name="Saturday";;
      esac
      schedule_desc="weekly on $day_name at $hour:$minute"
      ;;
    3)
      read -p "Enter day of month (1-31, default: 1): " day_of_month
      day_of_month="${day_of_month:-1}"
      read -p "Enter hour (0-23, default: 2): " hour
      hour="${hour:-2}"
      read -p "Enter minute (0-59, default: 15): " minute
      minute="${minute:-15}"
      cron_time="$minute $hour $day_of_month * *"
      schedule_desc="monthly on day $day_of_month at $hour:$minute"
      ;;
    4)
      read -p "Enter custom cron schedule (e.g., '15 2 * * 0'): " cron_time
      schedule_desc="custom schedule: $cron_time"
      ;;
    *)
      echo -e "${RED}${BOLD}Error: Invalid option!${NC}" >&2
      return 1
      ;;
  esac

  read -p "Add with dry-run for test? (y/n, default: n): " dry
  dry_flag=""
  if [[ "$dry" == [yY] ]]; then
    dry_flag="-d"
    schedule_desc="$schedule_desc (dry-run)"
  fi

  apply_config_permissions "$CONFIG_FILE"
  if [ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)" == "root" ] && [ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)" == "600" ]; then
    CRON="sudo crontab"
    echo -e "${YELLOW}The cron job will be installed for root as the config file is only readable by root!${NC}"
  else
    CRON="crontab"
    echo -e "${YELLOW}WARNING: The config file is not root 600; ensure only privileged users can read.${NC}"
  fi

  cron_command="$cron_time cd $SCRIPTPATH && ./removeOld.sh -c \"$CONFIG_FILE\" $dry_flag > /dev/null 2>&1"

  ($CRON -l 2>/dev/null || echo "") | grep -v "removeOld.sh -c \"$CONFIG_FILE\"" | { cat; echo "$cron_command"; } | $CRON -

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}${BOLD}Cleanup cron job added successfully!${NC}"
    echo -e "${GREEN}Schedule: ${NC}$schedule_desc"
    echo -e "${GREEN}Configuration: ${NC}$(basename "$CONFIG_FILE")"
  else
    echo -e "${RED}${BOLD}Error: Failed to add cleanup cron job!${NC}" >&2
    return 1
  fi

  return 0
}

while true; do
    show_menu
done