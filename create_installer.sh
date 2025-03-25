#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/create_installer.log"
STATUS_LOG="$SCRIPTPATH/create_installer_status.log"
TEMP_DIR="$SCRIPTPATH/temp_installer"
INSTALLER_DIR="$SCRIPTPATH/installers"
DIR=$(date +"%Y%m%d-%H%M%S")

while getopts "c:dv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-d] [-v]" >&2; exit 1;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file not specified! Use -c <config_file>" >&2
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE not found!" >&2
    exit 1
else
    . "$CONFIG_FILE"
fi

for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
COMPRESSION_FORMAT="${COMPRESSION_FORMAT:-tar.gz}"
INSTALLER_NAME="${INSTALLER_NAME:-installer-$DIR.zip}"

cleanup_installer() {
    log "INFO" "Installer creation interrupted! Cleaning up..."
    rm -rf "$TEMP_DIR"
    update_status "INTERRUPTED" "Installer creation process"
    notify "INTERRUPTED" "Installer creation process interrupted" "Installer"
}
trap cleanup_installer INT TERM

log "INFO" "Starting installer package creation"
update_status "STARTED" "Creating installer package"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR" "$INSTALLER_DIR"
    check_status $? "Creating temporary and installer directories" "Installer"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

if [ "$DRY_RUN" = false ]; then
    log "INFO" "Backing up database..."
    wp db export "$TEMP_DIR/db.sql" --path="$wpPath" --add-drop-table
    check_status $? "Exporting database" "Installer"
else
    log "INFO" "Dry run: Skipping database backup"
fi

if [ "$DRY_RUN" = false ]; then
    log "INFO" "Backing up files..."
    rsync -azvrh --progress "$wpPath/" "$TEMP_DIR/files/"
    check_status $? "Copying files" "Installer"
else
    log "INFO" "Dry run: Skipping files backup"
fi

if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating installation script..."
    cat << 'EOF' > "$TEMP_DIR/install.sh"
#!/usr/bin/env bash

for cmd in wp mysql unzip tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd is required but not installed!" >&2
        exit 1
    fi
done

INSTALL_DIR="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

read -p "Enter database name: " DB_NAME
read -p "Enter database user: " DB_USER
read -p "Enter database password: " DB_PASS
read -p "Enter new site URL (e.g., http://newdomain.com): " NEW_URL

echo "Creating database..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS $DB_NAME; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;" || {
    echo "Error: Failed to create database!" >&2
    exit 1
}

echo "Extracting files..."
mkdir -p files_temp
tar -xzf files.tar.gz -C files_temp
mv files_temp/* "$INSTALL_DIR/"
rm -rf files_temp files.tar.gz

echo "Importing database..."
wp db import db.sql --path="$INSTALL_DIR" || {
    echo "Error: Failed to import database!" >&2
    exit 1
}

echo "Updating site URL..."
wp search-replace "$(wp option get siteurl --path="$INSTALL_DIR")" "$NEW_URL" --path="$INSTALL_DIR" --all-tables || {
    echo "Error: Failed to update site URL!" >&2
    exit 1
}

rm db.sql install.sh

echo "Installation complete! Visit $NEW_URL to check your site."
EOF
    chmod +x "$TEMP_DIR/install.sh"
    check_status $? "Creating install script" "Installer"
else
    log "INFO" "Dry run: Skipping install script creation"
fi

if [ "$DRY_RUN" = false ]; then
    log "INFO" "Compressing files for installer..."
    cd "$TEMP_DIR"
    compress "files/" "files.tar.gz"
    rm -rf "$TEMP_DIR/files/"
    check_status $? "Cleaning up temporary files directory" "Installer"
else
    log "INFO" "Dry run: Skipping file compression"
fi

if [ "$DRY_RUN" = false ]; then
    log "INFO" "Creating final installer package..."
    cd "$TEMP_DIR"
    zip -r "$INSTALLER_DIR/$INSTALLER_NAME" db.sql files.tar.gz install.sh
    check_status $? "Packaging installer" "Installer"
else
    log "INFO" "Dry run: Skipping ZIP creation"
fi

if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Installer"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Installer package created successfully in ${DURATION}s"
update_status "SUCCESS" "Installer package created in ${DURATION}s"
notify "SUCCESS" "Installer package created successfully in ${DURATION}s" "Installer"

echo "Installer package created at: $INSTALLER_DIR/$INSTALLER_NAME"
echo "To install, extract the ZIP on the target server and run: ./install.sh"