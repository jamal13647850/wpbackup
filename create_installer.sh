#!/bin/bash
#
# Script: create_installer.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Creates a portable WordPress installer package with enhanced features.
# Version: 2.1 (as per original script)

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )" # Robust way to get script's directory
. "$SCRIPTPATH/common.sh" # Source common functions and variables

# --- Script Specific Paths and Variables ---
LOG_FILE="$SCRIPTPATH/logs/create_installer.log"
STATUS_LOG="$SCRIPTPATH/logs/create_installer_status.log"
TEMP_DIR="$SCRIPTPATH/temp_installer_$$" # Use PID for unique temp dir, cleaned by trap
INSTALLER_DIR="$SCRIPTPATH/installers"
DIR=$(date +"%Y%m%d-%H%M%S") # Timestamp for installer name

# --- Default values for script options ---
DRY_RUN=false
VERBOSE=false
DISABLE_PLUGINS=false     # Option to disable plugins during the installation process via install.sh
MULTISITE_SUPPORT=false   # Option to enable specific handling for multisite
EXCLUDE_PATTERNS=""       # Comma-separated patterns to exclude from file backup
CHUNK_SIZE="500M"         # Default chunk size for splitting large file archives
MEMORY_LIMIT="512M"       # Default PHP memory limit for operations within installer (if applicable)

# --- Parse Command Line Arguments ---
while getopts "c:f:dve:m:l:pMh?" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";; # e.g., zip, tar.gz
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        e) EXCLUDE_PATTERNS="$OPTARG";;
        m) MEMORY_LIMIT="$OPTARG";;
        l) CHUNK_SIZE="$OPTARG";;
        p) DISABLE_PLUGINS=true;;
        M) MULTISITE_SUPPORT=true;;
        h|?) # Help message
            echo -e "${GREEN}${BOLD}WordPress Installer Creator${NC}"
            echo -e "${CYAN}Usage: $0 -c <config_file> [options]${NC}"
            echo -e "${YELLOW}Options:${NC}"
            echo -e "  ${GREEN}-c <file>${NC}    Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  ${GREEN}-f <format>${NC}  Override final installer package compression format (currently only zip is supported by script logic)" # Clarified format usage
            echo -e "  ${GREEN}-d${NC}           Dry run (simulate without actual changes)"
            echo -e "  ${GREEN}-v${NC}           Verbose output (sets LOG_LEVEL to verbose)"
            echo -e "  ${GREEN}-e <patterns>${NC} Exclude patterns (comma separated, e.g. 'cache,uploads/large')"
            echo -e "  ${GREEN}-m <limit>${NC}   PHP memory limit for operations (default: ${MEMORY_LIMIT})"
            echo -e "  ${GREEN}-l <size>${NC}    Chunk size for splitting large file archives (default: ${CHUNK_SIZE})"
            echo -e "  ${GREEN}-p${NC}           Set installer to disable plugins during its execution"
            echo -e "  ${GREEN}-M${NC}           Enable special handling for multisite installations"
            echo -e "  ${GREEN}-h, -?${NC}       Show this help message"
            exit 0
            ;;
    esac
done

init_log "WordPress Installer Creator" # Initialize logging for this script

# --- Configuration File Handling ---
if [ -z "$CONFIG_FILE" ]; then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "installer"; then # Interactive selection
        log "ERROR" "Configuration file selection failed or was cancelled."
        exit 1
    fi
fi
process_config_file "$CONFIG_FILE" "Installer Creator" # Load and source the config

# Validate required variables from config (wpPath is crucial)
for var in wpPath; do
    if [ -z "${!var}" ]; then
        log "ERROR" "Required variable '$var' is not set in configuration file '$CONFIG_FILE'."
        exit 1
    fi
done

# Process custom configuration variables from sourced config file, with defaults
INCLUDE_EXTRA_FILES="${INCLUDE_EXTRA_FILES:-false}" # Include an 'extra_files' directory in the installer
SECURE_DB_CONFIG="${SECURE_DB_CONFIG:-true}"       # Use a separate secure file for DB credentials in generated wp-config.php
BACKUP_BEFORE_INSTALL="${BACKUP_BEFORE_INSTALL:-true}" # Generated installer will backup existing site
AUTO_OPTIMIZE_DB="${AUTO_OPTIMIZE_DB:-true}"       # Optimize DB dump (remove DEFINER, etc.)

# Validate WordPress path
if [ ! -d "$wpPath" ]; then
    log "ERROR" "WordPress path '$wpPath' does not exist."
    exit 1
fi

# Locate wp-config.php (either in wpPath or one level up)
if [ -f "$wpPath/wp-config.php" ]; then
    WP_CONFIG="$wpPath/wp-config.php"
elif [ -f "$(dirname "$wpPath")/wp-config.php" ]; then # Handles cases where wpPath is 'wordpress' subdir
    WP_CONFIG="$(dirname "$wpPath")/wp-config.php"
    log "INFO" "wp-config.php found in parent directory: $WP_CONFIG"
else
    log "ERROR" "wp-config.php not found in '$wpPath' or its parent directory."
    exit 1
fi

# --- Set operational variables with defaults ---
LOG_LEVEL="${VERBOSE:+verbose}" # Set by common.sh based on -v
LOG_LEVEL="${LOG_LEVEL:-normal}" # Default log level
NICE_LEVEL="${NICE_LEVEL:-19}"   # Default niceness for CPU-intensive tasks
COMPRESSION_FORMAT_FILES="${COMPRESSION_FORMAT_FILES:-tar.gz}" # Internal compression for files.tar.gz
INSTALLER_NAME="${INSTALLER_NAME:-installer-$wpHost-$DIR.zip}" # Default installer filename, using wpHost if defined in config
# OVERRIDE_FORMAT from -f is for the final ZIP, not internal tar.gz

# --- Helper Function: Convert human-readable size to bytes ---
# Args: $1 (size string like 500M, 1G)
convert_to_bytes() {
    local size_str=$1
    local size_val # Will hold numeric part
    local size_unit # Will hold unit (K, M, G, T)

    # Try numfmt first for robust conversion (GNU coreutils)
    if command_exists numfmt; then
        # numfmt --from=iec handles K, M, G, T suffixes correctly (1K=1024)
        # Check if input is valid for numfmt to avoid errors
        if echo "$size_str" | grep -qE '^[0-9]+[KkMmGgTt]?B?$'; then # Basic check for numfmt compatibility
            bytes=$(numfmt --from=iec "$size_str" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$bytes" ]; then
                echo "$bytes"
                return 0
            fi
        fi
    fi
    
    # Fallback to manual parsing if numfmt fails or is not available
    size_val=$(echo "$size_str" | sed 's/[^0-9]*//g') # Extract numeric part
    size_unit=$(echo "$size_str" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]') # Extract unit, uppercase

    case "$size_unit" in
        K|KB) echo $((size_val * 1024)) ;;
        M|MB) echo $((size_val * 1024 * 1024)) ;;
        G|GB) echo $((size_val * 1024 * 1024 * 1024)) ;;
        T|TB) echo $((size_val * 1024 * 1024 * 1024 * 1024)) ;;
        B|"") echo "$size_val" ;; # Assume bytes if no unit or B
        *)
            log "WARNING" "Could not parse size string '$size_str' in convert_to_bytes. Returning as is."
            echo "$size_val" # Fallback to numeric part if unit is unknown
            ;;
    esac
}

# --- Helper Function: Check available disk space ---
# Args: $1 (required space in MB), $2 (path to check disk space for)
check_disk_space() {
    local required_mb=$1
    local check_path="$2"
    
    if ! command_exists df; then
        log "WARNING" "'df' command not available. Skipping disk space check."
        if ! $QUIET; then echo -e "${YELLOW}Warning: Cannot check disk space ('df' command not found).${NC}"; fi
        return 0 # Assume enough space or let user decide
    fi
    
    # Get available disk space in Kilobytes, then convert to MB for comparison
    local available_kb
    available_kb=$(df -k "$check_path" | awk 'NR==2 {print $4}')
    
    if [ -z "$available_kb" ]; then
        log "WARNING" "Could not determine available disk space at '$check_path'."
        if ! $QUIET; then echo -e "${YELLOW}Warning: Could not determine available disk space.${NC}"; fi
        return 0
    fi
    
    local available_mb=$((available_kb / 1024))
    log "INFO" "Disk space check: Available=${available_mb}MB, Required=${required_mb}MB at '$check_path'."
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        log "ERROR" "Not enough disk space. Available: ${available_mb}MB, Required: ${required_mb}MB."
        if ! $QUIET; then
            echo -e "${RED}${BOLD}Error: Not enough disk space!${NC}" >&2
            echo -e "${YELLOW}Available: ${available_mb}MB, Required: ${required_mb}MB at '$check_path'.${NC}" >&2
        fi
        return 1
    fi
    return 0
}

# --- Helper Function: Estimate required disk space ---
# Returns estimated required space in MB
estimate_disk_space() {
    local wp_content_size_mb=0
    
    if ! command_exists du; then
        log "WARNING" "'du' command not available. Using a default estimate of 1500MB for required space."
        echo 1500 # Default estimate if 'du' is not found
        return
    fi

    # Estimate size of WordPress installation (wpPath) in MB
    wp_content_size_mb=$(du -sm "$wpPath" | awk '{print $1}')
    
    if [ -z "$wp_content_size_mb" ]; then
        log "WARNING" "Could not determine size of '$wpPath'. Using default estimate."
        wp_content_size_mb=500 # Default if size calculation fails
    fi
    log "INFO" "Estimated size of WordPress content ('$wpPath'): ${wp_content_size_mb}MB."
    
    # Estimate: 1x for current files, 1x for db dump, 1x for tar.gz, 0.5x for zip, 0.5x for temp operations
    # Total approx 3x the size of wpPath contents
    local estimated_required_mb=$((wp_content_size_mb * 3))
    # Add a buffer, e.g., 200MB
    estimated_required_mb=$((estimated_required_mb + 200))
    
    log "INFO" "Estimated total disk space required for installer creation: ${estimated_required_mb}MB."
    echo "$estimated_required_mb"
}

# --- Cleanup Function for Trap ---
cleanup_installer() {
    log "INFO" "Installer creation process ended. Cleaning up temporary directory: $TEMP_DIR ..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "Temporary directory $TEMP_DIR removed."
    fi
    # update_status is handled by the calling script or final status update
    # notify "INTERRUPTED" "Installer creation process interrupted by signal" "Installer Creator" # Can be too noisy
}
trap cleanup_installer EXIT INT TERM # Ensure cleanup on script exit or interruption

# --- Main Process Start ---
log "INFO" "Starting WordPress Installer package creation process."
update_status "STARTED" "Creating installer package for ${wpHost:-$(basename "$wpPath")}"

# Check for required system commands
REQUIRED_CMDS=("wp" "rsync" "zip" "tar" "sed" "awk" "df" "du" "split" "cat") # Added split and cat for chunking
check_requirements "${REQUIRED_CMDS[@]}" || {
    log "ERROR" "One or more required commands are missing. Aborting."
    # check_requirements already prints detailed error.
    exit 1
}

# Check if the WordPress installation is multisite
IS_MULTISITE="false" # Default to string "false" for easy placeholder replacement
if [ "$DRY_RUN" = "false" ]; then
    # Use --skip-plugins --skip-themes for faster check and to avoid potential errors from them
    if wp_cli core is-installed --path="$wpPath" --network --skip-plugins --skip-themes >/dev/null 2>&1; then
        IS_MULTISITE="true"
        log "INFO" "WordPress multisite installation detected at '$wpPath'."
        if ! $QUIET; then echo -e "${CYAN}${BOLD}WordPress multisite installation detected.${NC}"; fi
        
        if [ "$MULTISITE_SUPPORT" = "false" ]; then
            log "WARNING" "Multisite detected, but -M (multisite support) flag was not provided."
            if ! $QUIET; then
                echo -e "${YELLOW}Warning: This is a multisite installation, but specific multisite support for the installer is NOT enabled.${NC}"
                echo -e "${YELLOW}The generated installer might not work correctly for all subsites or network features.${NC}"
                echo -e "${YELLOW}It is highly recommended to use the -M flag for multisite installations.${NC}"
                read -r -p "Continue anyway? (y/N): " continue_anyway
                if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                    log "INFO" "User cancelled due to multisite warning without -M flag."
                    exit 0
                fi
            fi
        else
            log "INFO" "Multisite support (-M) is enabled."
            if ! $QUIET; then echo -e "${GREEN}Multisite support is enabled for the installer.${NC}"; fi
        fi
    else
        log "INFO" "Single site WordPress installation detected at '$wpPath'."
    fi
fi

# Estimate and check disk space
if [ "$DRY_RUN" = "false" ]; then
    ESTIMATED_REQUIRED_MB=$(estimate_disk_space)
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Checking available disk space (estimated requirement: ${ESTIMATED_REQUIRED_MB}MB)...${NC}"; fi
    check_disk_space "$ESTIMATED_REQUIRED_MB" "$SCRIPTPATH" || {
        log "ERROR" "Disk space check failed. Aborting."
        exit 1
    }
fi

# Create temporary and final installer directories
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Creating directories: TEMP_DIR='$TEMP_DIR', INSTALLER_DIR='$INSTALLER_DIR'."
    mkdir -p "$TEMP_DIR" "$INSTALLER_DIR"
    check_status $? "Creating temporary and final installer directories" "Installer Creator"
else
    log "INFO" "[Dry Run] Would create directories: TEMP_DIR='$TEMP_DIR', INSTALLER_DIR='$INSTALLER_DIR'."
fi

# Process exclude patterns for rsync
EXCLUDE_ARGS=""
if [ -n "$EXCLUDE_PATTERNS" ]; then
    log "INFO" "Processing exclude patterns: $EXCLUDE_PATTERNS"
    IFS=',' read -ra PATTERNS_ARRAY <<< "$EXCLUDE_PATTERNS" # Use different array name
    for pattern_item in "${PATTERNS_ARRAY[@]}"; do # Use different loop var name
        # Trim whitespace from pattern_item if any
        pattern_item_trimmed=$(echo "$pattern_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$pattern_item_trimmed" ]; then
            EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern_item_trimmed'"
        fi
    done
    log "INFO" "Final rsync exclude arguments: $EXCLUDE_ARGS"
fi

# --- Database Backup ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Starting database export to $TEMP_DIR/db.sql."
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Exporting database...${NC}"; fi
    
    DB_EXPORT_OPTS="--add-drop-table --skip-plugins --skip-themes" # Basic options
    # For multisite, exporting the primary site's DB context is usually sufficient for migration tools,
    # as network tables are included. Specific URL might not be needed unless wp-cli requires it.
    # if [ "$IS_MULTISITE" = "true" ] && [ "$MULTISITE_SUPPORT" = "true" ]; then
    #     DB_EXPORT_OPTS="$DB_EXPORT_OPTS --url=$(wp_cli option get siteurl --path="$wpPath")"
    # fi
    
    wp_cli db export "$TEMP_DIR/db.sql" --path="$wpPath" $DB_EXPORT_OPTS
    DB_EXPORT_STATUS=$? # Capture status immediately
    check_status $DB_EXPORT_STATUS "Exporting WordPress database" "Installer Creator"
    
    if [ -f "$TEMP_DIR/db.sql" ] && [ -s "$TEMP_DIR/db.sql" ]; then # Check if file exists and is not empty
        DB_SIZE_HR=$(human_readable_size "$(du -b "$TEMP_DIR/db.sql" | cut -f1)")
        log "INFO" "Database export successful. Size: $DB_SIZE_HR."
        if ! $QUIET; then echo -e "${GREEN}Database export successful. Size: ${NC}${DB_SIZE_HR}"; fi
        
        if [ "$AUTO_OPTIMIZE_DB" = "true" ]; then
            log "INFO" "Optimizing database export file..."
            if ! $QUIET; then echo -e "${CYAN}Optimizing database export (removing DEFINERs, standardizing SET NAMES)...${NC}"; fi
            # Remove DEFINER clauses which can cause import issues on different servers
            sed -i -E 's/\/\*!50013 DEFINER=`[^`]+`@`[^`]+` SQL SECURITY DEFINER \*\/[[:space:]]*//g' "$TEMP_DIR/db.sql"
            sed -i -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$TEMP_DIR/db.sql"
            # Standardize character set and collation statements to avoid conflicts
            sed -i 's/SET NAMES latin1/SET NAMES utf8mb4/g' "$TEMP_DIR/db.sql" # Example, adjust if needed
            sed -i 's/DEFAULT CHARSET=latin1/DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci/g' "$TEMP_DIR/db.sql" # Example
            log "INFO" "Database export optimization applied."
        fi
    else
        log "ERROR" "Database export failed or db.sql is empty. Aborting."
        exit 1
    fi
else
    log "INFO" "[Dry Run] Would export database to $TEMP_DIR/db.sql."
fi

# --- Files Backup ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Starting WordPress files backup from '$wpPath' to '$TEMP_DIR/files/'."
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Copying WordPress files...${NC}"; fi
    
    mkdir -p "$TEMP_DIR/files/" # Ensure target directory exists
    
    # Using eval with rsync due to EXCLUDE_ARGS containing quoted patterns
    # -a: archive mode (-rlptgoD), -z: compress, -v: verbose (for progress), -h: human-readable
    RSYNC_CMD="nice -n \"$NICE_LEVEL\" rsync -az --info=progress2 $EXCLUDE_ARGS \"$wpPath/\" \"$TEMP_DIR/files/\""
    log "DEBUG" "Executing rsync command: $RSYNC_CMD"
    eval "$RSYNC_CMD"
    check_status $? "Copying WordPress files using rsync" "Installer Creator"
    
    FILES_SIZE_HR=$(human_readable_size "$(du -sb "$TEMP_DIR/files" | cut -f1)")
    log "INFO" "WordPress files copied successfully. Total size: $FILES_SIZE_HR."
    if ! $QUIET; then echo -e "${GREEN}WordPress files copied. Total size: ${NC}${FILES_SIZE_HR}"; fi
    
    if [ "$INCLUDE_EXTRA_FILES" = "true" ] && [ -n "$EXTRA_FILES_PATH" ]; then
        if [ -d "$EXTRA_FILES_PATH" ]; then
            log "INFO" "Including extra files from '$EXTRA_FILES_PATH' into installer."
            if ! $QUIET; then echo -e "${CYAN}Including extra files from '${EXTRA_FILES_PATH}'...${NC}"; fi
            mkdir -p "$TEMP_DIR/extra_files"
            rsync -az --info=progress2 "$EXTRA_FILES_PATH/" "$TEMP_DIR/extra_files/"
            check_status $? "Copying extra files" "Installer Creator"
        else
            log "WARNING" "Extra files path '$EXTRA_FILES_PATH' configured but does not exist. Skipping."
            if ! $QUIET; then echo -e "${YELLOW}Warning: Extra files path '$EXTRA_FILES_PATH' does not exist. Skipping.${NC}"; fi
        fi
    fi
else
    log "INFO" "[Dry Run] Would copy WordPress files from '$wpPath' to '$TEMP_DIR/files/'."
    if [ "$INCLUDE_EXTRA_FILES" = "true" ] && [ -n "$EXTRA_FILES_PATH" ]; then
        log "INFO" "[Dry Run] Would include extra files from '$EXTRA_FILES_PATH'."
    fi
fi

# --- Create Installation Script (install.sh) ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Creating dynamic installation script: $TEMP_DIR/install.sh."
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Generating installation script (install.sh)...${NC}"; fi
    
    # Heredoc for install.sh - Ensure no unintended variable expansion within the heredoc itself.
    # Use single quotes for 'EOF' to prevent expansion of $variables from this (creator) script.
    # Placeholders like __MY_VAR__ will be replaced later using sed.
cat << 'INSTALL_SCRIPT_EOF' > "$TEMP_DIR/install.sh"
#!/bin/bash
# WordPress Auto-Installer Script
# Generated by WordPress Installer Creator
# Version: 2.1

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}      WordPress Installation Script     ${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "Installer Version: __INSTALLER_VERSION__"
echo -e "Generated on: __GENERATION_DATE__"
echo ""

INSTALL_DIR_AUTO="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )" # Installer's current directory

# --- Configuration Placeholders (to be replaced by creator script) ---
IS_MULTISITE_INSTALL="__MULTISITE_PLACEHOLDER__"
CREATOR_DISABLE_PLUGINS="__DISABLE_PLUGINS_PLACEHOLDER__"
CREATOR_BACKUP_BEFORE_INSTALL="__BACKUP_BEFORE_INSTALL_PLACEHOLDER__"
CREATOR_SECURE_DB_CONFIG="__SECURE_DB_CONFIG_PLACEHOLDER__"
CREATOR_PHP_MEMORY_LIMIT="__PHP_MEMORY_LIMIT_PLACEHOLDER__"

# --- Helper: Check Command Existence ---
command_exists_installer() { command -v "$1" >/dev/null 2>&1; }

# --- Prerequisite Checks ---
echo -e "${CYAN}Step 1: Checking prerequisites...${NC}"
REQUIRED_CMDS_INSTALLER=("wp" "mysql" "tar" "sed" "awk") # zip/unzip if files are zipped, tar if tar.gz
if [ -f "$INSTALL_DIR_AUTO/files.tar.gz" ]; then REQUIRED_CMDS_INSTALLER+=("tar" "gzip"); fi
if [ -f "$INSTALL_DIR_AUTO/files.tar.part.aa" ]; then REQUIRED_CMDS_INSTALLER+=("cat" "tar"); fi # For split files
if [ -f "$INSTALL_DIR_AUTO/package.zip" ]; then REQUIRED_CMDS_INSTALLER+=("unzip"); fi # If main package is zip (less likely for this structure)

MISSING_CMDS_INSTALLER=()
for cmd_check in "${REQUIRED_CMDS_INSTALLER[@]}"; do
    if ! command_exists_installer "$cmd_check"; then MISSING_CMDS_INSTALLER+=("$cmd_check"); fi
done

if [ ${#MISSING_CMDS_INSTALLER[@]} -gt 0 ]; then
    echo -e "${RED}${BOLD}Error: Required commands not found: ${MISSING_CMDS_INSTALLER[*]}${NC}" >&2
    echo -e "${YELLOW}Please install them and try again.${NC}" >&2; exit 1;
fi
echo -e "${GREEN}Prerequisites check passed.${NC}"

# --- User Input for Installation ---
echo -e "\n${CYAN}Step 2: Gathering Installation Details...${NC}"
read -r -p "Enter full path for WordPress installation (default: $INSTALL_DIR_AUTO): " WP_INSTALL_PATH
WP_INSTALL_PATH="${WP_INSTALL_PATH:-$INSTALL_DIR_AUTO}"

# Ensure WP_INSTALL_PATH is not just / or /root or similar sensitive locations by mistake
if [[ "$WP_INSTALL_PATH" == "/" || "$WP_INSTALL_PATH" == "/root" || "$WP_INSTALL_PATH" == "/home" ]]; then
    echo -e "${RED}${BOLD}Error: Installation path '$WP_INSTALL_PATH' is not allowed for safety reasons.${NC}" >&2; exit 1;
fi
mkdir -p "$WP_INSTALL_PATH" || { echo -e "${RED}${BOLD}Error: Could not create installation path '$WP_INSTALL_PATH'. Check permissions.${NC}"; exit 1; }
WP_INSTALL_PATH="$(cd "$WP_INSTALL_PATH" && pwd -P)" # Get absolute path

read -r -p "Enter new Site URL (e.g., http://yourdomain.com): " NEW_SITE_URL
while [ -z "$NEW_SITE_URL" ]; do echo -e "${YELLOW}Site URL cannot be empty.${NC}"; read -r -p "Site URL: " NEW_SITE_URL; done

echo -e "\n${CYAN}Database Configuration:${NC}"
read -r -p "Database Name: " DB_NAME_INPUT
while [ -z "$DB_NAME_INPUT" ]; do echo -e "${YELLOW}Database Name cannot be empty.${NC}"; read -r -p "Database Name: " DB_NAME_INPUT; done
read -r -p "Database User: " DB_USER_INPUT
while [ -z "$DB_USER_INPUT" ]; do echo -e "${YELLOW}Database User cannot be empty.${NC}"; read -r -p "Database User: " DB_USER_INPUT; done
read -r -s -p "Database Password: " DB_PASS_INPUT; echo
while [ -z "$DB_PASS_INPUT" ]; do echo -e "${YELLOW}Database Password cannot be empty.${NC}"; read -r -s -p "Database Password: " DB_PASS_INPUT; echo; done
read -r -p "Database Host (default: localhost): " DB_HOST_INPUT
DB_HOST_INPUT="${DB_HOST_INPUT:-localhost}"
read -r -p "Database Table Prefix (default: wp_): " DB_PREFIX_INPUT
DB_PREFIX_INPUT="${DB_PREFIX_INPUT:-wp_}"

# --- Confirmation ---
echo -e "\n${YELLOW}${BOLD}Please confirm installation details:${NC}"
echo -e "  WordPress Path: ${CYAN}$WP_INSTALL_PATH${NC}"
echo -e "  Site URL:       ${CYAN}$NEW_SITE_URL${NC}"
echo -e "  DB Name:        ${CYAN}$DB_NAME_INPUT${NC}"
echo -e "  DB User:        ${CYAN}$DB_USER_INPUT${NC}"
echo -e "  DB Host:        ${CYAN}$DB_HOST_INPUT${NC}"
echo -e "  DB Prefix:      ${CYAN}$DB_PREFIX_INPUT${NC}"
echo -e "  Multisite:      ${CYAN}$IS_MULTISITE_INSTALL${NC}"
read -r -p "Proceed with installation? (y/N): " CONFIRM_INSTALL
if [[ ! "$CONFIRM_INSTALL" =~ ^[Yy]$ ]]; then echo -e "${RED}Installation cancelled by user.${NC}"; exit 0; fi

# --- Pre-Installation Backup (if configured and WordPress exists) ---
if [ "$CREATOR_BACKUP_BEFORE_INSTALL" = "true" ] && [ -f "$WP_INSTALL_PATH/wp-config.php" ]; then
    echo -e "\n${CYAN}Step 3: Backing up existing WordPress installation at '$WP_INSTALL_PATH'...${NC}"
    SITE_BACKUP_DIR="$WP_INSTALL_PATH/../wp_backup_$(date +"%Y%m%d%H%M%S")_$$"
    mkdir -p "$SITE_BACKUP_DIR" || { echo -e "${RED}Failed to create backup dir $SITE_BACKUP_DIR${NC}"; exit 1; }
    echo -e "Backing up files to $SITE_BACKUP_DIR/files..."
    rsync -a --info=progress2 "$WP_INSTALL_PATH/" "$SITE_BACKUP_DIR/files/" && \
    echo -e "Backing up database to $SITE_BACKUP_DIR/database.sql.gz..." && \
    wp db export "$SITE_BACKUP_DIR/database.sql.gz" --path="$WP_INSTALL_PATH" --add-drop-table --allow-root && \
    echo -e "${GREEN}Existing site backup completed to $SITE_BACKUP_DIR.${NC}" || \
    echo -e "${YELLOW}Warning: Backup of existing site encountered issues. Check $SITE_BACKUP_DIR.${NC}"
fi

# --- File Extraction ---
echo -e "\n${CYAN}Step 4: Extracting WordPress files...${NC}"
cd "$INSTALL_DIR_AUTO" || { echo -e "${RED}Cannot change to installer script directory.${NC}"; exit 1; }

if [ -f "reassemble.sh" ]; then # Handle split archives
    echo -e "Split archive detected. Reassembling..."
    if ! bash ./reassemble.sh; then echo -e "${RED}Failed to reassemble files from parts.${NC}"; exit 1; fi
    # reassemble.sh should create files.tar and extract it. Let's assume it extracts to a 'files' subdir or similar.
    # For safety, this installer will then rsync from the reassembled 'files' directory.
    if [ ! -d "$INSTALL_DIR_AUTO/files_reassembled" ]; then # Adjust dir name if reassemble.sh uses different one
        echo -e "${RED}Reassembled files directory not found. Check reassemble.sh logic.${NC}"; exit 1;
    fi
    echo -e "Copying reassembled files to $WP_INSTALL_PATH..."
    rsync -a --info=progress2 "$INSTALL_DIR_AUTO/files_reassembled/" "$WP_INSTALL_PATH/" || { echo -e "${RED}Failed to copy reassembled files.${NC}"; exit 1; }
    rm -rf "$INSTALL_DIR_AUTO/files_reassembled" # Clean up
elif [ -f "files.tar.gz" ]; then # Handle single tar.gz
    echo -e "Extracting files.tar.gz to $WP_INSTALL_PATH..."
    # Ensure target is clean or handle existing files appropriately
    # For simplicity, this overwrites. Add rm -rf "$WP_INSTALL_PATH/*" if clean install is always needed.
    tar -xzf files.tar.gz -C "$WP_INSTALL_PATH/" || { echo -e "${RED}Failed to extract files.tar.gz.${NC}"; exit 1; }
else
    echo -e "${RED}Error: No WordPress file archive (files.tar.gz or split parts) found in installer.${NC}"; exit 1;
fi
echo -e "${GREEN}WordPress files extracted successfully to $WP_INSTALL_PATH.${NC}"

# Install extra_files if present
if [ -d "$INSTALL_DIR_AUTO/extra_files" ]; then
    echo -e "\n${CYAN}Step 5: Installing additional files...${NC}"
    rsync -a --info=progress2 "$INSTALL_DIR_AUTO/extra_files/" "$WP_INSTALL_PATH/" || \
    echo -e "${YELLOW}Warning: Some additional files might not have been copied correctly.${NC}"
    echo -e "${GREEN}Additional files installed.${NC}"
fi

# --- wp-config.php Setup ---
echo -e "\n${CYAN}Step 6: Configuring wp-config.php...${NC}"
cd "$WP_INSTALL_PATH" || { echo -e "${RED}Cannot change to WordPress installation path $WP_INSTALL_PATH.${NC}"; exit 1; }

if [ ! -f "wp-config-sample.php" ] && [ ! -f "wp-config.php" ]; then
    echo -e "${RED}Error: Neither wp-config.php nor wp-config-sample.php found in $WP_INSTALL_PATH.${NC}"; exit 1;
fi
if [ ! -f "wp-config.php" ]; then cp wp-config-sample.php wp-config.php; fi

# Set DB credentials and prefix
wp config set DB_NAME "$DB_NAME_INPUT" --type=string --quiet
wp config set DB_USER "$DB_USER_INPUT" --type=string --quiet
wp config set DB_PASSWORD "$DB_PASS_INPUT" --type=string --quiet
wp config set DB_HOST "$DB_HOST_INPUT" --type=string --quiet
wp config set table_prefix "$DB_PREFIX_INPUT" --type=string --quiet
wp config set WP_DEBUG false --raw --type=constant --quiet # Standard practice for live sites

# Generate new Salts
echo -e "Generating new security salts..."
wp config shuffle-salts --quiet || echo -e "${YELLOW}Warning: Failed to shuffle salts. Consider doing this manually.${NC}"


# Secure DB credentials if configured by creator script
if [ "$CREATOR_SECURE_DB_CONFIG" = "true" ]; then
    echo -e "Applying secure database credential storage..."
    DB_CREDS_SECURE_DIR="$WP_INSTALL_PATH/wp-content/secure_cfg" # Use a different name to avoid conflict
    DB_CREDS_SECURE_FILE="$DB_CREDS_SECURE_DIR/db_cfg.php" # Use a different name

    if ! grep -q "DB_CREDENTIALS_SECURE_FILE" "wp-config.php"; then
        mkdir -p "$DB_CREDS_SECURE_DIR"
        echo "<?php // Secure DB Credentials" > "$DB_CREDS_SECURE_FILE"
        echo "if(!defined('ABSPATH')) exit;" >> "$DB_CREDS_SECURE_FILE"
        echo "define('DB_NAME', '$DB_NAME_INPUT');" >> "$DB_CREDS_SECURE_FILE"
        echo "define('DB_USER', '$DB_USER_INPUT');" >> "$DB_CREDS_SECURE_FILE"
        echo "define('DB_PASSWORD', '$DB_PASS_INPUT');" >> "$DB_CREDS_SECURE_FILE"
        echo "define('DB_HOST', '$DB_HOST_INPUT');" >> "$DB_CREDS_SECURE_FILE"
        chmod 600 "$DB_CREDS_SECURE_FILE"
        chmod 700 "$DB_CREDS_SECURE_DIR" # Restrict directory access

        # Add include line at the top of wp-config.php, after <?php
        sed -i "/<?php/a \
define('DB_CREDENTIALS_SECURE_FILE', __DIR__ . '/wp-content/secure_cfg/db_cfg.php');\n\
if (file_exists(DB_CREDENTIALS_SECURE_FILE)) { require_once(DB_CREDENTIALS_SECURE_FILE); } else { error_log('FATAL: Secure DB config file not found.'); die('DB Config Error'); }\n" "wp-config.php"

        # Comment out original definitions using # or //
        sed -i -E "s/^(define\s*\(\s*'(DB_NAME|DB_USER|DB_PASSWORD|DB_HOST)'.*);/\/\* Commented by installer \*\/ \/\/\1;/" "wp-config.php"
        echo -e "${GREEN}Database credentials moved to secure file: $DB_CREDS_SECURE_FILE${NC}"
    else
        echo -e "${YELLOW}Secure database configuration appears to be already in place.${NC}"
    fi
fi
echo -e "${GREEN}wp-config.php configured.${NC}"

# --- Database Import ---
echo -e "\n${CYAN}Step 7: Importing database...${NC}"
# Create database if it doesn't exist (MySQL only)
echo -e "Attempting to create database '$DB_NAME_INPUT' if it doesn't exist..."
mysql -h "$DB_HOST_INPUT" -u "$DB_USER_INPUT" -p"$DB_PASS_INPUT" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_INPUT\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || \
    { echo -e "${RED}Failed to create database. Check user permissions or create it manually.${NC}"; exit 1; }

# Disable plugins before import if requested
ORIGINAL_ACTIVE_PLUGINS=""
if [ "$CREATOR_DISABLE_PLUGINS" = "true" ]; then
    echo -e "Temporarily deactivating plugins for database import..."
    ORIGINAL_ACTIVE_PLUGINS=$(wp plugin list --status=active --field=name --allow-root 2>/dev/null)
    wp plugin deactivate --all --allow-root || echo -e "${YELLOW}Warning: Some plugins might not have been deactivated.${NC}"
fi

echo -e "Importing SQL data from db.sql..."
# Using mysql client directly for potentially better performance and transaction control
# Add START TRANSACTION and COMMIT for atomicity
(echo "SET autocommit=0;"; echo "START TRANSACTION;"; cat "$INSTALL_DIR_AUTO/db.sql"; echo "COMMIT;") | \
mysql -h "$DB_HOST_INPUT" -u "$DB_USER_INPUT" -p"$DB_PASS_INPUT" "$DB_NAME_INPUT"
DB_IMPORT_STATUS=$?

if [ $DB_IMPORT_STATUS -ne 0 ]; then
    echo -e "${RED}${BOLD}Error: Database import failed! (Status: $DB_IMPORT_STATUS)${NC}" >&2
    # Attempt to rollback is not reliable with piped commands; manual check needed if this happens.
    echo -e "${YELLOW}The database might be in an inconsistent state. Manual check required.${NC}" >&2
    exit 1;
fi
echo -e "${GREEN}Database imported successfully.${NC}"

# --- Post-Import Tasks (URL update, etc.) ---
echo -e "\n${CYAN}Step 8: Finalizing installation...${NC}"
echo -e "Updating site URL and home URL..."
wp option update siteurl "$NEW_SITE_URL" --allow-root
wp option update home "$NEW_SITE_URL" --allow-root

# Search and replace old URLs. Get old URL from the imported DB.
OLD_SITE_URL_DB=$(wp option get siteurl --allow-root) # Get it from the newly imported DB
if [ -n "$OLD_SITE_URL_DB" ] && [ "$OLD_SITE_URL_DB" != "$NEW_SITE_URL" ]; then
    echo -e "Performing search-replace for URLs: $OLD_SITE_URL_DB -> $NEW_SITE_URL"
    if [ "$IS_MULTISITE_INSTALL" = "true" ]; then
        wp search-replace "$OLD_SITE_URL_DB" "$NEW_SITE_URL" --all-tables-with-prefix --network --report-changed-only --allow-root || \
        echo -e "${YELLOW}Warning: Multisite search-replace encountered issues.${NC}"
    else
        wp search-replace "$OLD_SITE_URL_DB" "$NEW_SITE_URL" --all-tables-with-prefix --report-changed-only --allow-root || \
        echo -e "${YELLOW}Warning: Search-replace encountered issues.${NC}"
    fi
else
    echo -e "Old URL matches new URL or could not be determined. Skipping extensive search-replace."
fi

# Reactivate original plugins if they were disabled
if [ "$CREATOR_DISABLE_PLUGINS" = "true" ] && [ -n "$ORIGINAL_ACTIVE_PLUGINS" ]; then
    echo -e "Re-activating original plugins..."
    for plugin_name_reactivate in $ORIGINAL_ACTIVE_PLUGINS; do
        wp plugin activate "$plugin_name_reactivate" --allow-root || \
        echo -e "${YELLOW}Warning: Failed to reactivate plugin '$plugin_name_reactivate'.${NC}"
    done
fi

# Flush rewrite rules
echo -e "Flushing rewrite rules..."
wp rewrite flush --hard --allow-root || echo -e "${YELLOW}Warning: Failed to flush rewrite rules.${NC}"

# Optimize database
echo -e "Optimizing database tables..."
wp db optimize --allow-root || echo -e "${YELLOW}Warning: Database optimization failed.${NC}"

# --- Set File Permissions (Basic) ---
echo -e "\n${CYAN}Step 9: Setting basic file permissions...${NC}"
find . -type d -exec chmod 755 {} \;
find . -type f -exec chmod 644 {} \;
chmod 600 wp-config.php # Extra protection for wp-config.php
if [ "$CREATOR_SECURE_DB_CONFIG" = "true" ] && [ -f "$DB_CREDS_SECURE_FILE" ]; then
    chmod 600 "$DB_CREDS_SECURE_FILE"
    chmod 700 "$DB_CREDS_SECURE_DIR"
fi
echo -e "${GREEN}Basic file permissions applied.${NC}"

# --- Cleanup Installer Files ---
echo -e "\n${CYAN}Step 10: Cleaning up installer files...${NC}"
cd "$INSTALL_DIR_AUTO" || echo "Warning: Could not change to $INSTALL_DIR_AUTO for cleanup."
rm -f "$INSTALL_DIR_AUTO/db.sql" "$INSTALL_DIR_AUTO/install.sh" "$INSTALL_DIR_AUTO/README.txt" "$INSTALL_DIR_AUTO/reassemble.sh" \
      "$INSTALL_DIR_AUTO/files.tar.gz" "$INSTALL_DIR_AUTO/files.tar.part.a"* 2>/dev/null
rm -rf "$INSTALL_DIR_AUTO/extra_files" 2>/dev/null
echo -e "${GREEN}Installer files cleaned up.${NC}"

# --- Installation Complete ---
echo -e "\n${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  WordPress Installation Successful!  ${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "Access your site at: ${CYAN}${NEW_SITE_URL}${NC}"
echo -e "Admin login: ${CYAN}${NEW_SITE_URL}/wp-admin/${NC}"
echo -e "\n${YELLOW}IMPORTANT: Review your site thoroughly. Check permalinks, plugin settings, and theme options.${NC}"
echo -e "Consider regenerating thumbnails if migrating media from a different setup."
echo -e "For security, delete this installer package from the server if you uploaded a ZIP."
exit 0

INSTALL_SCRIPT_EOF
    # End of Here Document for install.sh

    # Replace placeholders in the generated install.sh
    # Get current date for "Generated on"
    GENERATION_DATE_STR=$(date +"%Y-%m-%d %H:%M:%S %Z")
    sed -i "s|__MULTISITE_PLACEHOLDER__|$IS_MULTISITE|g" "$TEMP_DIR/install.sh"
    sed -i "s|__DISABLE_PLUGINS_PLACEHOLDER__|$DISABLE_PLUGINS|g" "$TEMP_DIR/install.sh"
    sed -i "s|__BACKUP_BEFORE_INSTALL_PLACEHOLDER__|$BACKUP_BEFORE_INSTALL|g" "$TEMP_DIR/install.sh"
    sed -i "s|__SECURE_DB_CONFIG_PLACEHOLDER__|$SECURE_DB_CONFIG|g" "$TEMP_DIR/install.sh"
    sed -i "s|__PHP_MEMORY_LIMIT_PLACEHOLDER__|$MEMORY_LIMIT|g" "$TEMP_DIR/install.sh"
    sed -i "s|__INSTALLER_VERSION__|2.1|g" "$TEMP_DIR/install.sh" # Version from this script
    sed -i "s|__GENERATION_DATE__|$GENERATION_DATE_STR|g" "$TEMP_DIR/install.sh"


    chmod +x "$TEMP_DIR/install.sh"
    check_status $? "Finalizing installation script (install.sh)" "Installer Creator"
else
    log "INFO" "[Dry Run] Would create dynamic installation script: $TEMP_DIR/install.sh."
fi

# --- Create README.txt ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Creating README.txt for the installer package."
    # Heredoc for README.txt
cat << 'README_EOF' > "$TEMP_DIR/README.txt"
WordPress Installer Package
===========================

This package contains files to install a WordPress website.

Package Contents:
-----------------
- install.sh: The main installation script. Run this on your server.
- db.sql: A dump of the WordPress database.
- files.tar.gz OR files.tar.part.aa, files.tar.part.ab, ...: Compressed WordPress core, themes, plugins, and uploads.
  (If split, use reassemble.sh first)
- reassemble.sh (if files are split): Script to combine split file archives.
- extra_files/ (optional): Contains any additional files/directories included during package creation.
- README.txt: This file.

Prerequisites for Target Server:
--------------------------------
- A LAMP/LEMP stack (Linux, Apache/Nginx, MySQL/MariaDB, PHP).
- PHP version compatible with the WordPress version being installed (check WordPress requirements).
- Required PHP extensions (e.g., mysqli, curl, gd, xml, mbstring).
- MySQL or MariaDB server accessible.
- WP-CLI (WordPress Command Line Interface) installed and in the server's PATH.
- Standard Unix utilities: tar, gzip, cat, sed, awk, rsync, mysql client.
- Sufficient disk space for extracted files and database.
- Shell access (SSH) to run the `install.sh` script.

Installation Steps:
-------------------
1.  Upload the ENTIRE installer package (e.g., installer-YYYYMMDD-HHMMSS.zip) to your target server.
2.  Extract the main ZIP package on the server. This will create a directory containing the files listed above.
3.  Navigate into the extracted directory using your terminal.
4.  Make the installation script executable: `chmod +x install.sh`
5.  Run the installation script: `./install.sh`
6.  Follow the on-screen prompts. You will be asked for:
    -   The full path where WordPress should be installed.
    -   The new Site URL for the WordPress installation.
    -   Database connection details (name, user, password, host).
    -   Database table prefix.
7.  The script will then:
    -   Check for prerequisites.
    -   Optionally back up any existing WordPress installation at the target path.
    -   Reassemble file archives if they were split.
    -   Extract WordPress files to the specified installation path.
    -   Install any included extra files.
    -   Configure `wp-config.php` with your database details.
    -   Optionally secure database credentials in a separate file.
    -   Create the database if it doesn't exist.
    -   Import the `db.sql` into the new database.
    -   Update site URLs and perform a search-replace in the database.
    -   Reactivate plugins (if they were temporarily disabled).
    -   Flush WordPress rewrite rules and optimize the database.
    -   Set basic file permissions.
    -   Clean up temporary installer files (db.sql, install.sh itself, etc. from the extracted package).

Post-Installation:
------------------
-   Verify your website is working correctly at the new URL.
-   Log in to the WordPress admin area (`NEW_SITE_URL/wp-admin/`) and check settings, permalinks, themes, and plugins.
-   Ensure your web server (Apache/Nginx) is correctly configured to serve the WordPress site from the installation path.
-   For security, it's good practice to delete the installer ZIP package and its extracted contents from the server after a successful installation.

Troubleshooting:
----------------
-   Check the `install.log` file (if created by a more advanced installer) or console output for errors.
-   Ensure file permissions and ownership are correct for your web server environment.
-   Verify PHP and MySQL versions meet WordPress requirements.
-   Check that all required PHP extensions are enabled.

This installer package was generated by the WordPress Installer Creator script.
README_EOF
    check_status $? "Creating README.txt" "Installer Creator"
else
    log "INFO" "[Dry Run] Would create README.txt."
fi

# --- Compress Files for Installer (including potential splitting) ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Preparing WordPress files for final packaging (compression/splitting)."
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Packaging WordPress files (may involve splitting if large)...${NC}"; fi
    
    # Change to TEMP_DIR to make archive paths relative within the package
    cd "$TEMP_DIR" || { log "ERROR" "Failed to change directory to $TEMP_DIR. Aborting."; exit 1; }
    
    CHUNK_SIZE_BYTES=$(convert_to_bytes "$CHUNK_SIZE")
    WP_FILES_DIR_PATH="$TEMP_DIR/files" # This is where rsync put the files
    
    # Check size of the 'files' directory (uncompressed content)
    if [ -d "$WP_FILES_DIR_PATH" ]; then
        ACTUAL_FILES_SIZE_BYTES=$(du -sb "$WP_FILES_DIR_PATH" | cut -f1)
        log "INFO" "Size of content in '$WP_FILES_DIR_PATH' is $(human_readable_size "$ACTUAL_FILES_SIZE_BYTES"). Chunk threshold is $(human_readable_size "$CHUNK_SIZE_BYTES")."

        if [ "$ACTUAL_FILES_SIZE_BYTES" -gt "$CHUNK_SIZE_BYTES" ]; then
            log "INFO" "Content size exceeds chunk threshold. Splitting files archive."
            if ! $QUIET; then echo -e "${YELLOW}WordPress files are large. Creating split tar archive (files.tar.part.*)...${NC}"; fi
            
            # Create a single tarball first, then split it.
            # This ensures atomicity of the tar operation before splitting.
            nice -n "$NICE_LEVEL" tar -cf "files.tar" -C "$(dirname "$WP_FILES_DIR_PATH")" "$(basename "$WP_FILES_DIR_PATH")"
            check_status $? "Creating intermediate 'files.tar' for splitting" "Installer Creator"

            nice -n "$NICE_LEVEL" split --numeric-suffixes=1 -a 2 -b "$CHUNK_SIZE" "files.tar" "files.tar.part."
            check_status $? "Splitting 'files.tar' into chunks" "Installer Creator"
            rm "files.tar" # Remove the large intermediate tar

            # Create reassemble.sh script
cat << 'REASSEMBLE_EOF' > "$TEMP_DIR/reassemble.sh"
#!/bin/bash
# Script to reassemble split WordPress file archives

echo "Reassembling split archives (files.tar.part.* into files.tar)..."
cat files.tar.part.* > files.tar
REASSEMBLE_STATUS=$?
if [ $REASSEMBLE_STATUS -ne 0 ]; then
    echo "Error: Failed to reassemble files. Aborting. (Status: $REASSEMBLE_STATUS)" >&2
    exit 1
fi
echo "Reassembly complete: files.tar created."

echo "Extracting reassembled files.tar into './files_reassembled/' directory..."
mkdir -p files_reassembled # Ensure target directory exists
tar -xf files.tar -C files_reassembled/
EXTRACT_STATUS=$?
if [ $EXTRACT_STATUS -ne 0 ]; then
    echo "Error: Failed to extract reassembled files.tar. Aborting. (Status: $EXTRACT_STATUS)" >&2
    rm files.tar # Clean up intermediate tar
    exit 1
fi
echo "Files extracted successfully to './files_reassembled/'."

echo "Cleaning up intermediate files (files.tar and parts)..."
rm files.tar files.tar.part.*
echo "Reassembly and extraction process complete."
exit 0
REASSEMBLE_EOF
            chmod +x "$TEMP_DIR/reassemble.sh"
            log "INFO" "reassemble.sh script created for split archive."
        else
            log "INFO" "Content size is within chunk threshold. Creating single files.tar.gz archive."
            nice -n "$NICE_LEVEL" tar -czf "files.tar.gz" -C "$(dirname "$WP_FILES_DIR_PATH")" "$(basename "$WP_FILES_DIR_PATH")"
            check_status $? "Compressing WordPress files into files.tar.gz" "Installer Creator"
        fi
        # Remove original 'files' directory from TEMP_DIR after archiving/splitting
        rm -rf "$WP_FILES_DIR_PATH" 
        log "INFO" "Original files directory '$WP_FILES_DIR_PATH' removed after packaging."
    else
        log "ERROR" "WordPress files directory '$WP_FILES_DIR_PATH' not found for packaging. Aborting."
        exit 1
    fi
else
    log "INFO" "[Dry Run] Would compress/split WordPress files in $TEMP_DIR."
fi


# --- Create Final Installer ZIP Package ---
PACKAGE_SIZE_HR="N/A (Dry Run)"
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Creating final installer ZIP package: $INSTALLER_DIR/$INSTALLER_NAME."
    if ! $QUIET; then echo -e "${CYAN}${BOLD}Creating final installer ZIP package...${NC}"; fi
    
    cd "$TEMP_DIR" || { log "ERROR" "Failed to change directory to $TEMP_DIR for final zipping. Aborting."; exit 1; }
    
    # Determine which set of files to include in the ZIP
    FILES_TO_ZIP="db.sql install.sh README.txt"
    if [ -f "reassemble.sh" ]; then # If split files were created
        FILES_TO_ZIP="$FILES_TO_ZIP reassemble.sh files.tar.part.a*" # Add reassemble script and all parts
    elif [ -f "files.tar.gz" ]; then # If single archive was created
        FILES_TO_ZIP="$FILES_TO_ZIP files.tar.gz"
    else
        log "ERROR" "No WordPress file archive (split parts or tar.gz) found in $TEMP_DIR. Cannot create ZIP."
        exit 1
    fi
    
    # Add extra_files directory to ZIP if it exists
    if [ -d "extra_files" ]; then
        FILES_TO_ZIP="$FILES_TO_ZIP extra_files/"
    fi
    
    log "DEBUG" "Files to be included in ZIP: $FILES_TO_ZIP"
    # Using eval to handle wildcard expansion for files.tar.part.a* correctly
    eval zip -q -r \""$INSTALLER_DIR/$INSTALLER_NAME"\" $FILES_TO_ZIP
    check_status $? "Packaging final installer ZIP" "Installer Creator"
    
    if [ -f "$INSTALLER_DIR/$INSTALLER_NAME" ]; then
        PACKAGE_SIZE_BYTES=$(du -b "$INSTALLER_DIR/$INSTALLER_NAME" | cut -f1)
        PACKAGE_SIZE_HR=$(human_readable_size "$PACKAGE_SIZE_BYTES")
        log "INFO" "Final installer package '$INSTALLER_DIR/$INSTALLER_NAME' created. Size: $PACKAGE_SIZE_HR."
    else
        log "ERROR" "Final installer ZIP package was not created."
        PACKAGE_SIZE_HR="Error creating package"
    fi
else
    log "INFO" "[Dry Run] Would create final installer ZIP: $INSTALLER_DIR/$INSTALLER_NAME."
fi

# Final cleanup of TEMP_DIR is handled by the EXIT trap (cleanup_installer)

# --- Process Finish ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration "$DURATION")

log "INFO" "WordPress Installer Creator script finished in ${FORMATTED_DURATION}."
update_status "SUCCESS" "Installer package ${INSTALLER_NAME} created in ${FORMATTED_DURATION}."
# Send notification if configured (NOTIFY_ON_SUCCESS should be from common.sh or config)
if [ "${NOTIFY_ON_SUCCESS:-true}" = true ] && [ "$DRY_RUN" = "false" ]; then
    notify "SUCCESS" "Installer package '$INSTALLER_NAME' (Size: $PACKAGE_SIZE_HR) created successfully in ${FORMATTED_DURATION}. Location: $INSTALLER_DIR" "Installer Creator"
fi

if ! $QUIET; then
    echo -e "\n${GREEN}${BOLD}===============================================${NC}"
    echo -e "${GREEN}${BOLD}  Installer Package Creation Complete!  ${NC}"
    echo -e "${GREEN}${BOLD}===============================================${NC}"
    if [ "$DRY_RUN" = "false" ]; then
        echo -e "${GREEN}Package Location: ${CYAN}$INSTALLER_DIR/$INSTALLER_NAME${NC}"
        echo -e "${GREEN}Package Size:     ${CYAN}$PACKAGE_SIZE_HR${NC}"
    else
        echo -e "${YELLOW}[Dry Run Mode] No package was actually created.${NC}"
        echo -e "${YELLOW}Simulated package name: $INSTALLER_NAME at $INSTALLER_DIR${NC}"
    fi
    echo -e "${GREEN}Time Taken:       ${CYAN}$FORMATTED_DURATION${NC}"
    if [ "$DRY_RUN" = "false" ]; then
        echo -e "\n${CYAN}${BOLD}Next Steps:${NC}"
        echo -e "1. Upload '${CYAN}$INSTALLER_NAME${NC}' to your target server."
        echo -e "2. Extract the ZIP archive on the server."
        echo -e "3. Navigate to the extracted directory and run: ${BOLD}./install.sh${NC}"
    fi
fi

exit 0 # Exit successfully