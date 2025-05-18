#!/bin/bash
# Enhanced WordPress Installer Creator Script
# This script creates a portable WordPress installer package
# Author: WordPress Backup System
# Version: 2.1

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/create_installer.log"
STATUS_LOG="$SCRIPTPATH/create_installer_status.log"
TEMP_DIR="$SCRIPTPATH/temp_installer"
INSTALLER_DIR="$SCRIPTPATH/installers"
DIR=$(date +"%Y%m%d-%H%M%S")

# Default values
DRY_RUN=false
VERBOSE=false
DISABLE_PLUGINS=false
MULTISITE_SUPPORT=false
EXCLUDE_PATTERNS=""
CHUNK_SIZE="500M"  # Default chunk size for splitting large files
MEMORY_LIMIT="512M"  # Default memory limit for PHP operations

# Parse command line arguments
while getopts "c:f:dve:m:l:pMh?" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        f) OVERRIDE_FORMAT="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        e) EXCLUDE_PATTERNS="$OPTARG";;
        m) MEMORY_LIMIT="$OPTARG";;
        l) CHUNK_SIZE="$OPTARG";;
        p) DISABLE_PLUGINS=true;;
        M) MULTISITE_SUPPORT=true;;
        h|?)
            echo -e "${GREEN}${BOLD}WordPress Installer Creator${NC}"
            echo -e "${CYAN}Usage: $0 -c <config_file> [options]${NC}"
            echo -e "${YELLOW}Options:${NC}"
            echo -e "  ${GREEN}-c <file>${NC}    Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  ${GREEN}-f <format>${NC}  Override compression format (zip, tar.gz, tar)"
            echo -e "  ${GREEN}-d${NC}           Dry run (no actual changes)"
            echo -e "  ${GREEN}-v${NC}           Verbose output"
            echo -e "  ${GREEN}-e <patterns>${NC} Exclude patterns (comma separated, e.g. 'cache,uploads/large')"
            echo -e "  ${GREEN}-m <limit>${NC}   PHP memory limit for operations (default: 512M)"
            echo -e "  ${GREEN}-l <size>${NC}    Chunk size for large files (default: 500M)"
            echo -e "  ${GREEN}-p${NC}           Disable plugins during installation"
            echo -e "  ${GREEN}-M${NC}           Enable multisite support"
            echo -e "  ${GREEN}-h, -?${NC}       Show this help message"
            exit 0
            ;;
    esac
done

init_log "WordPress Installer Creator"

# Check for configuration file
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "installer"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
fi

# Process the configuration file
process_config_file "$CONFIG_FILE" "Installer"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Process custom configuration variables with defaults
INCLUDE_EXTRA_FILES="${INCLUDE_EXTRA_FILES:-false}"
SECURE_DB_CONFIG="${SECURE_DB_CONFIG:-true}"
BACKUP_BEFORE_INSTALL="${BACKUP_BEFORE_INSTALL:-true}"
AUTO_OPTIMIZE_DB="${AUTO_OPTIMIZE_DB:-true}"

# Validate WordPress path
if [ ! -d "$wpPath" ]; then
    echo -e "${RED}${BOLD}Error: WordPress path $wpPath does not exist!${NC}" >&2
    exit 1
fi

# Check if wp-config.php exists
if [ ! -f "$wpPath/wp-config.php" ]; then
    echo -e "${RED}${BOLD}Error: wp-config.php not found in $wpPath!${NC}" >&2
    echo -e "${YELLOW}This does not appear to be a valid WordPress installation.${NC}" >&2
    exit 1
fi

# Set configuration variables with defaults
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
COMPRESSION_FORMAT="${OVERRIDE_FORMAT:-${COMPRESSION_FORMAT:-tar.gz}}"
INSTALLER_NAME="${INSTALLER_NAME:-installer-$DIR.zip}"

# Function to convert size string to bytes (with fallback)
convert_to_bytes() {
    local size_str=$1
    local size_num=${size_str%[kKmMgGtT]*}
    local size_unit=${size_str#$size_num}
    
    # Try using numfmt if available
    if command -v numfmt >/dev/null 2>&1; then
        if numfmt --from=iec "$size_str" >/dev/null 2>&1; then
            numfmt --from=iec "$size_str"
            return 0
        fi
    fi
    
    # Fallback calculation
    case ${size_unit,,} in
        k|kb) echo $((size_num * 1024)) ;;
        m|mb) echo $((size_num * 1024 * 1024)) ;;
        g|gb) echo $((size_num * 1024 * 1024 * 1024)) ;;
        t|tb) echo $((size_num * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo "$size_num" ;; # Assume bytes if no unit specified
    esac
}

# Function to check disk space
check_disk_space() {
    local required_space=$1  # in MB
    local path=$2
    
    # Get available disk space in MB
    local available_space
    if command -v df >/dev/null 2>&1; then
        available_space=$(df -m "$path" | awk 'NR==2 {print $4}')
        log "INFO" "Available disk space: ${available_space}MB, Required: ${required_space}MB"
        
        if [ "$available_space" -lt "$required_space" ]; then
            echo -e "${RED}${BOLD}Error: Not enough disk space!${NC}" >&2
            echo -e "${YELLOW}Available: ${available_space}MB, Required: ${required_space}MB${NC}" >&2
            return 1
        fi
    else
        log "WARNING" "df command not available, skipping disk space check"
        echo -e "${YELLOW}Warning: Cannot check disk space (df command not available)${NC}"
    fi
    return 0
}

# Function to estimate required disk space
estimate_disk_space() {
    local wp_size=0
    
    # Get WordPress size in MB
    if command -v du >/dev/null 2>&1; then
        wp_size=$(du -sm "$wpPath" | awk '{print $1}')
        log "INFO" "WordPress size: ${wp_size}MB"
    else
        # If du is not available, use a conservative estimate
        wp_size=500
        log "WARNING" "du command not available, using estimated size: ${wp_size}MB"
    fi
    
    # We need approximately 3x the WordPress size for the installer creation process
    # (original files + database dump + compressed files + final package)
    echo $((wp_size * 3))
}

# Cleanup function for unexpected exits
cleanup_installer() {
    log "INFO" "Installer creation interrupted! Cleaning up..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    update_status "INTERRUPTED" "Installer creation process"
    notify "INTERRUPTED" "Installer creation process interrupted" "Installer"
}
trap cleanup_installer INT TERM

# Start the process
log "INFO" "Starting installer package creation"
update_status "STARTED" "Creating installer package"

# Check if we have the required commands
check_requirements "wp" "rsync" "zip" "tar" || {
    echo -e "${RED}${BOLD}Error: Missing required commands!${NC}" >&2
    exit 1
}

# Check if WordPress is multisite
IS_MULTISITE=false
if [ "$DRY_RUN" = false ]; then
    if wp core is-installed --path="$wpPath" --network >/dev/null 2>&1; then
        IS_MULTISITE=true
        log "INFO" "WordPress multisite installation detected"
        echo -e "${CYAN}${BOLD}WordPress multisite installation detected${NC}"
        
        if [ "$MULTISITE_SUPPORT" = false ]; then
            echo -e "${YELLOW}Warning: This is a multisite installation but multisite support is not enabled.${NC}"
            echo -e "${YELLOW}Use the -M flag to enable multisite support.${NC}"
            read -p "Continue anyway? (y/n): " continue_anyway
            if [[ "$continue_anyway" != [yY] ]]; then
                echo -e "${CYAN}Exiting at user request.${NC}"
                exit 0
            fi
        fi
    fi
fi

# Estimate required disk space and check if we have enough
REQUIRED_SPACE=$(estimate_disk_space)
if [ "$DRY_RUN" = false ]; then
    echo -e "${CYAN}${BOLD}Checking disk space...${NC}"
    check_disk_space "$REQUIRED_SPACE" "$SCRIPTPATH" || exit 1
fi

# Create directories if not in dry run mode
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR" "$INSTALLER_DIR"
    check_status $? "Creating temporary and installer directories" "Installer"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

# Process exclude patterns
EXCLUDE_ARGS=""
if [ -n "$EXCLUDE_PATTERNS" ]; then
    IFS=',' read -ra PATTERNS <<< "$EXCLUDE_PATTERNS"
    for pattern in "${PATTERNS[@]}"; do
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'"
    done
    log "INFO" "Using exclude patterns: $EXCLUDE_PATTERNS"
fi

# Backup database
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Backing up database..."
    echo -e "${CYAN}${BOLD}Exporting database...${NC}"
    
    # Set PHP memory limit for database export
    PHP_OPTS="--skip-plugins --skip-themes"
    if [ "$IS_MULTISITE" = true ] && [ "$MULTISITE_SUPPORT" = true ]; then
        PHP_OPTS="$PHP_OPTS --url=$(wp option get siteurl --path="$wpPath")"
    fi
    
    nice -n "$NICE_LEVEL" wp db export "$TEMP_DIR/db.sql" --path="$wpPath" --add-drop-table $PHP_OPTS
    DB_EXPORT_STATUS=$?
    check_status $DB_EXPORT_STATUS "Exporting database" "Installer"
    
    # Verify database export was successful
    if [ $DB_EXPORT_STATUS -eq 0 ] && [ -f "$TEMP_DIR/db.sql" ]; then
        # Get database size
        DB_SIZE=$(du -h "$TEMP_DIR/db.sql" | cut -f1)
        log "INFO" "Database export size: $DB_SIZE"
        echo -e "${GREEN}Database export size: ${NC}${DB_SIZE}"
        
        # Optimize the database export if configured
        if [ "$AUTO_OPTIMIZE_DB" = true ]; then
            echo -e "${CYAN}Optimizing database export...${NC}"
            # Remove potentially problematic queries
            sed -i '/^\/\*!50013 DEFINER=/d' "$TEMP_DIR/db.sql"
            # Remove any SET NAMES or character set that might conflict
            sed -i 's/SET NAMES.*/SET NAMES utf8mb4;/g' "$TEMP_DIR/db.sql"
            log "INFO" "Database export optimized"
        fi
    else
        echo -e "${RED}${BOLD}Error: Database export failed or file not created!${NC}" >&2
        # Clean up any partial files
        if [ -f "$TEMP_DIR/db.sql" ]; then
            rm -f "$TEMP_DIR/db.sql"
        fi
        exit 1
    fi
else
    log "INFO" "Dry run: Skipping database backup"
fi

# Backup files
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Backing up files..."
    echo -e "${CYAN}${BOLD}Copying WordPress files...${NC}"
    
    # Create files directory
    mkdir -p "$TEMP_DIR/files/"
    
    # Use rsync with exclude patterns
    eval nice -n "$NICE_LEVEL" rsync -azvrh --progress $EXCLUDE_ARGS "$wpPath/" "$TEMP_DIR/files/"
    check_status $? "Copying files" "Installer"
    
    # Get files size
    FILES_SIZE=$(du -sh "$TEMP_DIR/files" | cut -f1)
    log "INFO" "Files backup size: $FILES_SIZE"
    echo -e "${GREEN}Files backup size: ${NC}${FILES_SIZE}"
    
    # Include extra files if configured
    if [ "$INCLUDE_EXTRA_FILES" = true ] && [ -n "$EXTRA_FILES_PATH" ]; then
        if [ -d "$EXTRA_FILES_PATH" ]; then
            echo -e "${CYAN}Including extra files from ${EXTRA_FILES_PATH}...${NC}"
            mkdir -p "$TEMP_DIR/extra_files"
            rsync -azh "$EXTRA_FILES_PATH/" "$TEMP_DIR/extra_files/"
            check_status $? "Copying extra files" "Installer"
        else
            log "WARNING" "Extra files path $EXTRA_FILES_PATH does not exist"
            echo -e "${YELLOW}Warning: Extra files path $EXTRA_FILES_PATH does not exist${NC}"
        fi
    fi
else
    log "INFO" "Dry run: Skipping files backup"
fi

# Create installation script
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating installation script..."
    echo -e "${CYAN}${BOLD}Creating installation script...${NC}"
    
    # Create the install.sh script with enhanced features
    cat << 'EOF' > "$TEMP_DIR/install.sh"
#!/bin/bash
# WordPress Installer Script
# This script installs WordPress from a backup package
# Version: 2.1

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Banner
echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}      WordPress Installer Script        ${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"

# Check requirements
echo -e "${CYAN}Checking requirements...${NC}"
REQUIRED_COMMANDS=("wp" "mysql" "unzip" "tar" "php")
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    echo -e "${RED}${BOLD}Error: Required commands not found: ${MISSING_COMMANDS[*]}${NC}" >&2
    echo -e "${YELLOW}Please install the missing packages and try again.${NC}" >&2
    exit 1
fi

# Get installation directory
INSTALL_DIR="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
echo -e "${GREEN}Installation directory: ${BOLD}$INSTALL_DIR${NC}"

# Check if this is a multisite installation
IS_MULTISITE=__MULTISITE_PLACEHOLDER__

# Check if we should backup before installation
BACKUP_BEFORE_INSTALL=__BACKUP_BEFORE_INSTALL__

# Check if we should use secure DB config
SECURE_DB_CONFIG=__SECURE_DB_CONFIG__

# Check server compatibility
echo -e "${CYAN}Checking server compatibility...${NC}"
PHP_VERSION=$(php -r 'echo PHP_VERSION;')
echo -e "${GREEN}PHP Version: ${BOLD}$PHP_VERSION${NC}"

# Get minimum PHP version from WordPress
MIN_PHP_VERSION="5.6"
if [ "$(printf '%s\n' "$MIN_PHP_VERSION" "$PHP_VERSION" | sort -V | head -n1)" != "$MIN_PHP_VERSION" ]; then
    echo -e "${RED}${BOLD}Error: PHP version $PHP_VERSION is lower than required $MIN_PHP_VERSION${NC}" >&2
    exit 1
fi

# Check PHP modules
REQUIRED_MODULES=("mysqli" "curl" "gd" "xml" "mbstring")
MISSING_MODULES=()

for module in "${REQUIRED_MODULES[@]}"; do
    if ! php -m | grep -q "$module"; then
        MISSING_MODULES+=("$module")
    fi
done

if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    echo -e "${YELLOW}Warning: Recommended PHP modules not found: ${MISSING_MODULES[*]}${NC}"
    read -p "Continue anyway? (y/n): " continue_anyway
    if [[ "$continue_anyway" != [yY] ]]; then
        echo -e "${CYAN}Exiting at user request.${NC}"
        exit 0
    fi
fi

# Check if destination already has WordPress files
if [ -f "$INSTALL_DIR/wp-config.php" ] && [ "$BACKUP_BEFORE_INSTALL" = true ]; then
    echo -e "${YELLOW}Warning: WordPress files already exist in the destination directory.${NC}"
    read -p "Would you like to backup existing files before proceeding? (y/n): " backup_existing
    if [[ "$backup_existing" == [yY] ]]; then
        BACKUP_DIR="$INSTALL_DIR/pre_install_backup_$(date +"%Y%m%d-%H%M%S")"
        echo -e "${CYAN}Backing up existing files to $BACKUP_DIR...${NC}"
        mkdir -p "$BACKUP_DIR"
        rsync -a --exclude="pre_install_backup_*" "$INSTALL_DIR/" "$BACKUP_DIR/"
        echo -e "${GREEN}Backup completed successfully.${NC}"
    fi
fi

# Get database information
echo -e "${CYAN}${BOLD}Database Configuration${NC}"
read -p "Enter database name: " DB_NAME
while [ -z "$DB_NAME" ]; do
    echo -e "${YELLOW}Database name cannot be empty.${NC}"
    read -p "Enter database name: " DB_NAME
done

read -p "Enter database user: " DB_USER
while [ -z "$DB_USER" ]; do
    echo -e "${YELLOW}Database user cannot be empty.${NC}"
    read -p "Enter database user: " DB_USER
done

read -p "Enter database password: " DB_PASS
while [ -z "$DB_PASS" ]; do
    echo -e "${YELLOW}Database password cannot be empty.${NC}"
    read -p "Enter database password: " DB_PASS
done

read -p "Enter database host (default: localhost): " DB_HOST
DB_HOST="${DB_HOST:-localhost}"

read -p "Enter database prefix (default: wp_): " DB_PREFIX
DB_PREFIX="${DB_PREFIX:-wp_}"

# Get site URL
read -p "Enter new site URL (e.g., http://newdomain.com): " NEW_URL
while [ -z "$NEW_URL" ]; do
    echo -e "${YELLOW}Site URL cannot be empty.${NC}"
    read -p "Enter new site URL (e.g., http://newdomain.com): " NEW_URL
done

# Test database connection
echo -e "${CYAN}Testing database connection...${NC}"
if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}${BOLD}Error: Could not connect to database!${NC}" >&2
    echo -e "${YELLOW}Please check your database credentials and try again.${NC}" >&2
    exit 1
fi

# Create database
echo -e "${CYAN}${BOLD}Creating database...${NC}"
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
    echo -e "${RED}${BOLD}Error: Failed to create database!${NC}" >&2
    exit 1
}

# Check for split files
if [ -f "reassemble.sh" ]; then
    echo -e "${CYAN}${BOLD}Reassembling split files...${NC}"
    bash ./reassemble.sh || {
        echo -e "${RED}${BOLD}Error: Failed to reassemble files!${NC}" >&2
        exit 1
    }
else
    # Extract files
    echo -e "${CYAN}${BOLD}Extracting files...${NC}"
    mkdir -p files_temp
    tar -xzf files.tar.gz -C files_temp || {
        echo -e "${RED}${BOLD}Error: Failed to extract files!${NC}" >&2
        exit 1
    }
fi

echo -e "${CYAN}Moving files to installation directory...${NC}"
rsync -a files_temp/ "$INSTALL_DIR/" || {
    echo -e "${RED}${BOLD}Error: Failed to move files!${NC}" >&2
    exit 1
}

# Handle extra files if they exist
if [ -d "extra_files" ]; then
    echo -e "${CYAN}Installing extra files...${NC}"
    rsync -a extra_files/ "$INSTALL_DIR/" || {
        echo -e "${YELLOW}Warning: Failed to install some extra files${NC}"
    }
fi

# Clean up extraction files
rm -rf files_temp files.tar.gz 2>/dev/null
rm -f files.tar.part.* 2>/dev/null

# Create wp-config.php
echo -e "${CYAN}${BOLD}Updating wp-config.php...${NC}"
if [ -f "$INSTALL_DIR/wp-config.php" ]; then
    # Update database settings in wp-config.php
    sed -i "s/define( *'DB_NAME', *'[^']*' *);/define( 'DB_NAME', '$DB_NAME' );/g" "$INSTALL_DIR/wp-config.php"
    sed -i "s/define( *'DB_USER', *'[^']*' *);/define( 'DB_USER', '$DB_USER' );/g" "$INSTALL_DIR/wp-config.php"
    sed -i "s/define( *'DB_PASSWORD', *'[^']*' *);/define( 'DB_PASSWORD', '$DB_PASS' );/g" "$INSTALL_DIR/wp-config.php"
    sed -i "s/define( *'DB_HOST', *'[^']*' *);/define( 'DB_HOST', '$DB_HOST' );/g" "$INSTALL_DIR/wp-config.php"
    
    # Update table prefix if needed
    if [ "$DB_PREFIX" != "wp_" ]; then
        sed -i "s/\$table_prefix *= *'[^']*';/\$table_prefix = '$DB_PREFIX';/g" "$INSTALL_DIR/wp-config.php"
    fi
    
    # Secure database credentials if configured
    if [ "$SECURE_DB_CONFIG" = true ]; then
        echo -e "${CYAN}Securing database credentials...${NC}"
        
        # Check if wp-config already has security constants
        if ! grep -q "DB_CREDENTIALS_FILE" "$INSTALL_DIR/wp-config.php"; then
            # Create a separate file for database credentials
            DB_CREDS_DIR="$INSTALL_DIR/wp-content/secure"
            mkdir -p "$DB_CREDS_DIR"
            
            # Create the credentials file with restricted permissions
            cat > "$DB_CREDS_DIR/db-config.php" << EOL
<?php
// Secure database credentials - Do not modify directly
define('DB_NAME', '$DB_NAME');
define('DB_USER', '$DB_USER');
define('DB_PASSWORD', '$DB_PASS');
define('DB_HOST', '$DB_HOST');
EOL
            
            # Secure the file
            chmod 600 "$DB_CREDS_DIR/db-config.php"
            
            # Update wp-config.php to use the secure file
            sed -i '/define.*DB_NAME/i // Database credentials stored in separate secure file\ndefine("DB_CREDENTIALS_FILE", dirname(__FILE__) . "/wp-content/secure/db-config.php");\nif (file_exists(DB_CREDENTIALS_FILE)) {\n    require_once(DB_CREDENTIALS_FILE);\n}' "$INSTALL_DIR/wp-config.php"
            
            # Comment out the original definitions
            sed -i 's/^define( *.(DB_NAME|DB_USER|DB_PASSWORD|DB_HOST)/\/\/ $0/g' "$INSTALL_DIR/wp-config.php"
            
            echo -e "${GREEN}Database credentials secured in separate file.${NC}"
        else
            echo -e "${YELLOW}Secure database configuration already exists.${NC}"
        fi
    fi
else
    echo -e "${RED}${BOLD}Error: wp-config.php not found!${NC}" >&2
    exit 1
fi

# Import database
echo -e "${CYAN}${BOLD}Importing database...${NC}"
wp config set DB_NAME "$DB_NAME" --path="$INSTALL_DIR"
wp config set DB_USER "$DB_USER" --path="$INSTALL_DIR"
wp config set DB_PASSWORD "$DB_PASS" --path="$INSTALL_DIR"
wp config set DB_HOST "$DB_HOST" --path="$INSTALL_DIR"

# Check if we should disable plugins during import
DISABLE_PLUGINS=__DISABLE_PLUGINS_PLACEHOLDER__
if [ "$DISABLE_PLUGINS" = true ]; then
    echo -e "${CYAN}Temporarily disabling plugins...${NC}"
    # Save the list of active plugins before disabling
    ACTIVE_PLUGINS=$(wp plugin list --status=active --field=name --path="$INSTALL_DIR" 2>/dev/null)
    wp plugin deactivate --all --path="$INSTALL_DIR" || echo -e "${YELLOW}Warning: Could not disable plugins${NC}"
fi

# Create database backup before import if requested
if [ "$BACKUP_BEFORE_INSTALL" = true ]; then
    # Check if database already has tables
    TABLES_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SHOW TABLES FROM \`$DB_NAME\`;" | wc -l)
    if [ "$TABLES_COUNT" -gt 1 ]; then
        echo -e "${YELLOW}Database already contains tables. Creating backup...${NC}"
        BACKUP_FILE="$INSTALL_DIR/db_backup_$(date +"%Y%m%d-%H%M%S").sql"
        wp db export "$BACKUP_FILE" --path="$INSTALL_DIR" || {
            echo -e "${YELLOW}Warning: Could not create database backup${NC}"
        }
        echo -e "${GREEN}Database backup created: $BACKUP_FILE${NC}"
    fi
fi

# Import the database with transaction support
echo -e "${CYAN}Importing database with transaction support...${NC}"
(
    echo "START TRANSACTION;"
    cat db.sql
    echo "COMMIT;"
) | mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"

IMPORT_STATUS=$?
if [ $IMPORT_STATUS -ne 0 ]; then
    echo -e "${RED}${BOLD}Error: Database import failed! Rolling back...${NC}" >&2
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "ROLLBACK;"
    exit 1
fi

# Verify database import was successful
TABLES_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SHOW TABLES FROM \`$DB_NAME\`;" | wc -l)
if [ "$TABLES_COUNT" -le 1 ]; then
    echo -e "${RED}${BOLD}Error: Database import verification failed. No tables found!${NC}" >&2
    exit 1
fi

# Update site URL
echo -e "${CYAN}${BOLD}Updating site URL...${NC}"
OLD_URL=$(wp option get siteurl --path="$INSTALL_DIR")
echo -e "${GREEN}Old URL: ${BOLD}$OLD_URL${NC}"
echo -e "${GREEN}New URL: ${BOLD}$NEW_URL${NC}"

if [ "$IS_MULTISITE" = true ]; then
    echo -e "${CYAN}Updating URLs for multisite installation...${NC}"
    # Update main site URL
    wp search-replace "$OLD_URL" "$NEW_URL" --path="$INSTALL_DIR" --all-tables --network
    
    # Update home URL
    wp option update home "$NEW_URL" --path="$INSTALL_DIR"
    
    # Update network URLs
    wp site list --field=url --path="$INSTALL_DIR" | while read -r site_url; do
        if [ "$site_url" != "$OLD_URL" ]; then
            NEW_SUBSITE_URL="${NEW_URL}${site_url#$OLD_URL}"
            echo "Updating subsite: $site_url -> $NEW_SUBSITE_URL"
            wp search-replace "$site_url" "$NEW_SUBSITE_URL" --path="$INSTALL_DIR" --all-tables --url="$site_url"
        fi
    done
else
    # Standard search-replace for single site
    wp search-replace "$OLD_URL" "$NEW_URL" --path="$INSTALL_DIR" --all-tables || {
        echo -e "${RED}${BOLD}Error: Failed to update site URL!${NC}" >&2
        exit 1
    }
fi

# Reactivate plugins if they were disabled
if [ "$DISABLE_PLUGINS" = true ] && [ -n "$ACTIVE_PLUGINS" ]; then
    echo -e "${CYAN}Reactivating essential plugins...${NC}"
    # Reactivate each plugin that was previously active
    for plugin in $ACTIVE_PLUGINS; do
        wp plugin activate "$plugin" --path="$INSTALL_DIR" 2>/dev/null || {
            echo -e "${YELLOW}Warning: Could not reactivate plugin: $plugin${NC}"
        }
    done
fi

# Flush rewrite rules
echo -e "${CYAN}Flushing rewrite rules...${NC}"
wp rewrite flush --path="$INSTALL_DIR" || echo -e "${YELLOW}Warning: Could not flush rewrite rules${NC}"

# Optimize database after installation
echo -e "${CYAN}Optimizing database...${NC}"
wp db optimize --path="$INSTALL_DIR" || echo -e "${YELLOW}Warning: Could not optimize database${NC}"

# Clean up
echo -e "${CYAN}Cleaning up...${NC}"
rm -f db.sql install.sh reassemble.sh 2>/dev/null
rm -rf extra_files 2>/dev/null

echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo -e "${GREEN}Your WordPress site has been installed at: ${BOLD}$NEW_URL${NC}"
echo -e "${GREEN}Admin URL: ${BOLD}${NEW_URL}/wp-admin/${NC}"

# Provide additional information
echo -e "${CYAN}${BOLD}Next steps:${NC}"
echo -e "1. Make sure your web server is configured correctly"
echo -e "2. Visit your site and verify everything works"
echo -e "3. Update permalinks if needed"
echo -e "4. Review and activate plugins as needed"

echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}      Installation Completed!           ${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
EOF

    # Replace placeholders with actual values
    sed -i "s/__MULTISITE_PLACEHOLDER__/$IS_MULTISITE/" "$TEMP_DIR/install.sh"
    sed -i "s/__DISABLE_PLUGINS_PLACEHOLDER__/$DISABLE_PLUGINS/" "$TEMP_DIR/install.sh"
    sed -i "s/__BACKUP_BEFORE_INSTALL__/$BACKUP_BEFORE_INSTALL/" "$TEMP_DIR/install.sh"
    sed -i "s/__SECURE_DB_CONFIG__/$SECURE_DB_CONFIG/" "$TEMP_DIR/install.sh"
    
    # Make the script executable
    chmod +x "$TEMP_DIR/install.sh"
    check_status $? "Creating install script" "Installer"
else
    log "INFO" "Dry run: Skipping install script creation"
fi

# Create a README file
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating README file..."
    cat << 'EOF' > "$TEMP_DIR/README.txt"
WordPress Installer Package
==========================

This package contains everything needed to install a WordPress site on a new server.

Contents:
- install.sh: The installation script
- db.sql: Database backup
- files.tar.gz: WordPress files
- extra_files: Additional files (if included)

Installation Instructions:
1. Upload this entire package to the new server
2. Extract the package
3. Run the install.sh script: ./install.sh
4. Follow the prompts to complete the installation

Requirements:
- PHP 7.0 or higher
- MySQL 5.6 or higher
- Apache or Nginx web server
- WP-CLI installed and in your PATH

Security Features:
- Optional secure database credential storage
- Transaction-based database import
- Pre-installation backup of existing files and database

For support, contact your system administrator.
EOF
    check_status $? "Creating README file" "Installer"
else
    log "INFO" "Dry run: Skipping README creation"
fi

# Compress files for installer
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Compressing files for installer..."
    echo -e "${CYAN}${BOLD}Compressing WordPress files...${NC}"
    
    cd "$TEMP_DIR" || exit 1
    
    # Convert chunk size to bytes
    CHUNK_SIZE_BYTES=$(convert_to_bytes "$CHUNK_SIZE")
    
    # Check if files are large and need to be split
    FILES_SIZE_BYTES=$(du -sb files | cut -f1)
    
    if [ "$FILES_SIZE_BYTES" -gt "$CHUNK_SIZE_BYTES" ]; then
        log "INFO" "Files are large ($(human_readable_size "$FILES_SIZE_BYTES")), using split archives"
        echo -e "${YELLOW}Files are large ($(human_readable_size "$FILES_SIZE_BYTES")), creating split archives...${NC}"
        
        # Create tar file in chunks
        nice -n "$NICE_LEVEL" tar -cf - files | nice -n "$NICE_LEVEL" split -b "$CHUNK_SIZE" - "files.tar.part."
        check_status $? "Creating split archives" "Installer"
        
        # Create a script to reassemble the parts
        cat << 'EOF' > "$TEMP_DIR/reassemble.sh"
#!/bin/bash
echo "Reassembling split archives..."
cat files.tar.part.* > files.tar
echo "Extracting files..."
tar -xf files.tar
rm files.tar files.tar.part.*
echo "Files have been reassembled and extracted."
EOF
        chmod +x "$TEMP_DIR/reassemble.sh"
        
        # Remove the original files directory
        rm -rf "$TEMP_DIR/files/"
    else
        # Regular compression for smaller sites
        nice -n "$NICE_LEVEL" tar -czf "files.tar.gz" files/
        check_status $? "Compressing files" "Installer"
        
        # Remove the original files directory
        rm -rf "$TEMP_DIR/files/"
    fi
else
    log "INFO" "Dry run: Skipping file compression"
fi

# Create final installer package
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating final installer package..."
    echo -e "${CYAN}${BOLD}Creating final installer package...${NC}"
    
    cd "$TEMP_DIR" || exit 1
    
    # Check if we have split archives
    if [ -f "$TEMP_DIR/reassemble.sh" ]; then
        # Include extra_files directory if it exists
        if [ -d "$TEMP_DIR/extra_files" ]; then
            zip -r "$INSTALLER_DIR/$INSTALLER_NAME" db.sql files.tar.part.* reassemble.sh install.sh README.txt extra_files/
        else
            zip -r "$INSTALLER_DIR/$INSTALLER_NAME" db.sql files.tar.part.* reassemble.sh install.sh README.txt
        fi
    else
        # Include extra_files directory if it exists
        if [ -d "$TEMP_DIR/extra_files" ]; then
            zip -r "$INSTALLER_DIR/$INSTALLER_NAME" db.sql files.tar.gz install.sh README.txt extra_files/
        else
            zip -r "$INSTALLER_DIR/$INSTALLER_NAME" db.sql files.tar.gz install.sh README.txt
        fi
    fi
    
    check_status $? "Packaging installer" "Installer"
    
    # Get the final package size
    PACKAGE_SIZE=$(du -h "$INSTALLER_DIR/$INSTALLER_NAME" | cut -f1)
    log "INFO" "Final installer package size: $PACKAGE_SIZE"
else
    log "INFO" "Dry run: Skipping ZIP creation"
fi

# Clean up
if [ "$DRY_RUN" = false ]; then
    echo -e "${CYAN}${BOLD}Cleaning up temporary files...${NC}"
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Installer"
else
    # Make sure we don't leave any temp directories even in dry run mode
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
fi

# Finish
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Installer package created successfully in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Installer package created in ${FORMATTED_DURATION}"
notify "SUCCESS" "Installer package created successfully in ${FORMATTED_DURATION}" "Installer"

echo -e "${GREEN}${BOLD}Installer package created successfully!${NC}"
echo -e "${GREEN}Package location: ${NC}${INSTALLER_DIR}/${INSTALLER_NAME}"
echo -e "${GREEN}Package size: ${NC}${PACKAGE_SIZE:-Unknown}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
echo -e "${CYAN}${BOLD}To install, extract the ZIP on the target server and run: ./install.sh${NC}"

