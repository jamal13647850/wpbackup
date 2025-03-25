#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/staging.log"
STATUS_LOG="$SCRIPTPATH/staging_status.log"
TEMP_DIR="$SCRIPTPATH/temp_staging"
STAGING_DIR_SUFFIX="staging"

DRY_RUN=false
VERBOSE=false
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
    eval "$(load_config "$CONFIG_FILE")"
fi

# Check required variable
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

# Set defaults if not provided in config
STAGING_PATH="${stagingPath:-${wpPath}-${STAGING_DIR_SUFFIX}}"
SITE_URL=$(wp option get siteurl --path="$wpPath")
STAGING_URL="${stagingUrl:-${SITE_URL}/${STAGING_DIR_SUFFIX}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
DB_NAME=$(wp config get DB_NAME --path="$wpPath")
STAGING_DB_NAME="${stagingDbName:-${DB_NAME}_staging}"
DB_USER=$(wp config get DB_USER --path="$wpPath")
DB_PASS=$(wp config get DB_PASSWORD --path="$wpPath")

cleanup_staging() {
    cleanup "Staging process" "Staging"
    rm -rf "$TEMP_DIR"
}
trap cleanup_staging INT TERM

log "INFO" "Starting staging environment creation for $wpPath"
update_status "STARTED" "Staging creation for $wpPath"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR"
    check_status $? "Creating temporary directory $TEMP_DIR" "Staging"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

# Step 1: Copy files
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Copying files from $wpPath to $STAGING_PATH..."
    nice -n "$NICE_LEVEL" rsync -av --progress "$wpPath/" "$STAGING_PATH/"
    check_status $? "Copying files to staging directory" "Staging"
else
    log "INFO" "Dry run: Skipping file copy"
fi

# Step 2: Create and import database
if [ "$DRY_RUN" = false ]; then
    # Check if stagingDbName is provided; if not, create a new database
    if [ -z "$stagingDbName" ]; then
        log "INFO" "Creating staging database $STAGING_DB_NAME..."
        mysql -u root -e "CREATE DATABASE IF NOT EXISTS $STAGING_DB_NAME; GRANT ALL PRIVILEGES ON $STAGING_DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;"
        check_status $? "Creating staging database" "Staging"
    else
        log "INFO" "Using existing staging database $STAGING_DB_NAME from config"
    fi

    log "INFO" "Exporting database from $wpPath..."
    wp db export "$TEMP_DIR/db.sql" --path="$wpPath" --add-drop-table
    check_status $? "Exporting production database" "Staging"

    log "INFO" "Importing database to $STAGING_DB_NAME..."
    if [ -n "$stagingDbName" ]; then
        wp db import "$TEMP_DIR/db.sql" --path="$STAGING_PATH"
    else
        wp db import "$TEMP_DIR/db.sql" --path="$STAGING_PATH" --dbname="$STAGING_DB_NAME"
    fi
    check_status $? "Importing database to staging" "Staging"
else
    log "INFO" "Dry run: Skipping database creation and import"
fi

# Step 3: Update wp-config.php if a new database was created
if [ "$DRY_RUN" = false ] && [ -z "$stagingDbName" ]; then
    log "INFO" "Updating wp-config.php for staging environment..."
    cp "$STAGING_PATH/wp-config.php" "$STAGING_PATH/wp-config.php.bak"
    check_status $? "Backing up wp-config.php" "Staging"
    sed -i "s/define('DB_NAME', '$DB_NAME');/define('DB_NAME', '$STAGING_DB_NAME');/" "$STAGING_PATH/wp-config.php"
    check_status $? "Updating wp-config.php database name" "Staging"
else
    log "INFO" "Dry run or existing staging database: Skipping wp-config.php update"
fi

# Step 4: Update site URL in database
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Updating site URL to $STAGING_URL in staging database..."
    wp search-replace "$SITE_URL" "$STAGING_URL" --path="$STAGING_PATH" --all-tables
    check_status $? "Updating site URL in staging database" "Staging"
else
    log "INFO" "Dry run: Skipping site URL update"
fi

# Cleanup temporary files
if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Staging"
else
    log "INFO" "Dry run: Skipping cleanup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
CURRENT_DATE=$(date '+%Y-%m-%d')
log "INFO" "Staging environment created successfully at $STAGING_PATH in ${DURATION}s"
update_status "SUCCESS" "Staging creation completed in ${DURATION}s"
notify "SUCCESS" "Staging environment created successfully at $STAGING_PATH in ${DURATION}s on $CURRENT_DATE" "Staging"

echo "Staging environment created at: $STAGING_PATH"
echo "Access it at: $STAGING_URL"
echo "Database: $STAGING_DB_NAME"