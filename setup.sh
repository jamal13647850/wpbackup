#!/bin/bash
# setup.sh - WordPress backup system setup script
# Author: System Administrator
# Last updated: 2025-05-16

# Determine script path
SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check required commands
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

# Function to create directory if it doesn't exist
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

# Function to set permissions
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

# Function to create a new configuration file
create_config() {
    local config_name="$1"
    local config_file="$SCRIPTPATH/configs/$config_name.conf"
    
    if [ -f "$config_file" ]; then
        echo -e "${YELLOW}${BOLD}Warning: Configuration file $config_name.conf already exists.${NC}"
        read -p "Do you want to overwrite it? (y/n): " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo -e "${YELLOW}Configuration creation aborted.${NC}"
            return 0
        fi
    fi
    
    echo -e "${CYAN}${BOLD}Creating new configuration file: $config_name.conf${NC}"
    
    # Get configuration details
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
    read -p "WordPress Path: " wp_path
    while [ -z "$wp_path" ]; do
        echo -e "${YELLOW}WordPress Path cannot be empty.${NC}"
        read -p "WordPress Path: " wp_path
    done
    
    read -p "Max File Size for Backup (default: 50m): " max_size
    max_size="${max_size:-50m}"
    
    echo -e "${GREEN}Enter backup retention settings:${NC}"
    read -p "Backup Retention Duration in days (default: 30): " retention
    retention="${retention:-30}"
    
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
    
    # Create the configuration file
    cat > "$config_file" << EOF
# SSH settings
destinationPort=$ssh_port
destinationUser="$ssh_user"
destinationIP="$ssh_ip"
destinationDbBackupPath="$db_path"
destinationFilesBackupPath="$files_path"
privateKeyPath="$key_path"

# WordPress settings
wpPath="$wp_path"
maxSize="$max_size"

# Removal settings
BACKUP_RETAIN_DURATION=$retention

# Performance settings
NICE_LEVEL=$nice_level

# Notification settings
EOF

    if [ -n "$notify_method" ]; then
        echo "NOTIFY_METHOD=\"$notify_method\"  # Comma-separated: email, slack, telegram" >> "$config_file"
        
        if [ -n "$notify_email" ]; then
            echo "NOTIFY_EMAIL=\"$notify_email\"  # For email notifications" >> "$config_file"
        fi
        
        if [ -n "$slack_webhook" ]; then
            echo "SLACK_WEBHOOK_URL=\"$slack_webhook\"  # For Slack notifications" >> "$config_file"
        fi
        
        if [ -n "$telegram_token" ]; then
            echo "TELEGRAM_BOT_TOKEN=\"$telegram_token\"  # For Telegram notifications" >> "$config_file"
        fi
        
        if [ -n "$telegram_chat_id" ]; then
            echo "TELEGRAM_CHAT_ID=\"$telegram_chat_id\"  # For Telegram chat ID" >> "$config_file"
        fi
    fi
    
    echo -e "${GREEN}${BOLD}Configuration file created: $config_file${NC}"
    
    # Ask if user wants to encrypt the configuration
    read -p "Do you want to encrypt this configuration file? (y/n): " encrypt
    if [[ "$encrypt" == [yY] ]]; then
        if command_exists gpg; then
            gpg --symmetric --cipher-algo AES256 --output "$config_file.gpg" "$config_file"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${BOLD}Configuration file encrypted: $config_file.gpg${NC}"
                echo -e "${YELLOW}Removing unencrypted configuration file...${NC}"
                rm -f "$config_file"
            else
                echo -e "${RED}${BOLD}Error: Failed to encrypt configuration file${NC}" >&2
            fi
        else
            echo -e "${RED}${BOLD}Error: gpg is not installed. Cannot encrypt the configuration file.${NC}" >&2
        fi
    fi
    
    return 0
}

# Function to set up cron jobs
setup_cron() {
    echo -e "${CYAN}${BOLD}Setting up cron jobs...${NC}"
    
    read -p "Do you want to set up automated backups via cron? (y/n): " setup_cron
    if [[ "$setup_cron" != [yY] ]]; then
        echo -e "${YELLOW}Cron setup skipped.${NC}"
        return 0
    fi
    
    # List available configuration files
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
            schedule_desc="weekly on $(case $day_of_week in
                0) echo "Sunday";;
                1) echo "Monday";;
                2) echo "Tuesday";;
                3) echo "Wednesday";;
                4) echo "Thursday";;
                5) echo "Friday";;
                6) echo "Saturday";;
            esac) at $hour:$minute"
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
    
    # Create cron job
    cron_command="$cron_time cd $SCRIPTPATH && ./$(basename "$backup_script") -c \"$CONFIG_FILE\" $incremental_flag $location_flag > /dev/null 2>&1"
    
    # Add to crontab
    (crontab -l 2>/dev/null || echo "") | grep -v "$(basename "$backup_script") -c \"$CONFIG_FILE\"" | { cat; echo "$cron_command"; } | crontab -
    
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

# Function to test SSH connection
test_ssh_connection() {
    echo -e "${CYAN}${BOLD}Testing SSH connection...${NC}"
    
    # List available configuration files
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
    
    # Source the config file
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        if ! command_exists gpg; then
            echo -e "${RED}${BOLD}Error: gpg is not installed but required for encrypted config files!${NC}" >&2
            return 1
        fi
        
        # Load encrypted configuration
        source <(gpg --quiet --decrypt "$CONFIG_FILE" 2>/dev/null)
    else
        source "$CONFIG_FILE"
    fi
    
    # Check required SSH variables
    for var in destinationPort destinationUser destinationIP privateKeyPath; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}${BOLD}Error: Required SSH variable $var is not set in the configuration file!${NC}" >&2
            return 1
        fi
    done
    
    # Test SSH connection
    echo -e "${CYAN}Testing SSH connection to ${destinationUser}@${destinationIP}:${destinationPort}...${NC}"
    ssh -p "${destinationPort}" -i "${privateKeyPath}" -o ConnectTimeout=10 "${destinationUser}@${destinationIP}" "echo 'SSH connection successful!'" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}SSH connection successful!${NC}"
        
        # Test remote directories
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

# Main menu function
show_menu() {
    clear
    echo -e "${BLUE}${BOLD}=== WordPress Backup System Setup ===${NC}"
    echo -e "${CYAN}1. Create directory structure${NC}"
    echo -e "${CYAN}2. Create new configuration${NC}"
    echo -e "${CYAN}3. Set up cron jobs${NC}"
    echo -e "${CYAN}4. Test SSH connection${NC}"
    echo -e "${CYAN}5. Set file permissions${NC}"
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
            read -p "Enter configuration name: " config_name
            create_config "$config_name"
            read -p "Press Enter to continue..."
            ;;
        3)
            echo -e "${BLUE}${BOLD}=== Setting Up Cron Jobs ===${NC}"
            setup_cron
            read -p "Press Enter to continue..."
            ;;
        4)
            echo -e "${BLUE}${BOLD}=== Testing SSH Connection ===${NC}"
            test_ssh_connection
            read -p "Press Enter to continue..."
            ;;
        5)
            echo -e "${BLUE}${BOLD}=== Setting File Permissions ===${NC}"
            echo -e "${CYAN}Setting executable permissions on script files...${NC}"
            chmod +x "$SCRIPTPATH"/*.sh
            echo -e "${CYAN}Setting secure permissions on configs directory...${NC}"
            chmod 700 "$SCRIPTPATH/configs"
            echo -e "${GREEN}${BOLD}Permissions set successfully!${NC}"
            read -p "Press Enter to continue..."
            ;;
        0)
            echo -e "${GREEN}${BOLD}Thank you for using WordPress Backup System Setup!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}${BOLD}Invalid option!${NC}"
            read -p "Press Enter to continue..."
            ;;
    esac
}

# Check for required commands
echo -e "${CYAN}Checking for required commands...${NC}"
check_requirements "ssh" "rsync" "zip" "tar" || {
    echo -e "${RED}${BOLD}Please install the missing dependencies and run the script again.${NC}" >&2
    exit 1
}

# Main loop
while true; do
    show_menu
done
