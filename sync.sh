#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/sync.log"
STATUS_LOG="$SCRIPTPATH/sync_status.log"
TEMP_DIR="$SCRIPTPATH/temp_sync"
STAGING_DIR_SUFFIX="staging"

DRY_RUN=false
VERBOSE=false
DIRECTION=""
SYNC_TYPE=""
while getopts "c:t:d:pv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        t) SYNC_TYPE="$OPTARG";;
        d) DIRECTION="$OPTARG";;
        p) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> -t <db|files|both> -d <push|pull> [-p] [-v]" >&2; exit 1;;
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

if [ -z "$DIRECTION" ] || [ "$DIRECTION" != "push" ] && [ "$DIRECTION" != "pull" ]; then
    echo "Error: Invalid or missing direction! Use -d <push|pull>" >&2
    exit 1
fi

if [ -z "$SYNC_TYPE" ] || [ "$SYNC_TYPE" != "db" ] && [ "$SYNC_TYPE" != "files" ] && [ "$SYNC_TYPE" != "both" ]; then
    echo "Error: Invalid or missing sync type! Use -t <db|files|both>" >&2
    exit 1
fi

for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

STAGING_PATH="${stagingPath:-${wpPath}-${STAGING_DIR_SUFFIX}}"
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
DB_NAME=$(wp config get DB_NAME --path="$wpPath" 2>/dev/null || echo "$wpPath_db")
STAGING_DB_NAME="${stagingDbName:-${DB_NAME}_staging}"
DB_USER=$(wp config get DB_USER --path="$wpPath" 2>/dev/null || echo "root")
DB_PASS=$(wp config get DB_PASSWORD --path="$wpPath" 2>/dev/null || echo "")
SITE_URL=$(wp option get siteurl --path="$wpPath" 2>/dev/null || echo "$wpUrl")
STAGING_URL="${stagingUrl:-${SITE_URL}/${STAGING_DIR_SUFFIX}}"

cleanup_sync() {
    cleanup "Sync process" "Sync"
    rm -rf "$TEMP_DIR"
}
trap cleanup_sync INT TERM

log "INFO" "Starting sync process: $DIRECTION ($SYNC_TYPE) between $wpPath and $STAGING_PATH"
update_status "STARTED" "Sync process: $DIRECTION ($SYNC_TYPE)"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR"
    check_status $? "Creating temporary directory $TEMP_DIR" "Sync"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

sync_files() {
    local source_path=$1
    local dest_path=$2
    if [ "$DRY_RUN" = false ]; then
        log "INFO" "Syncing files from $source_path to $dest_path..."
        nice -n "$NICE_LEVEL" rsync -av --progress --delete "$source_path/" "$dest_path/"
        check_status $? "Syncing files from $source_path to $dest_path" "Sync"
    else
        log "INFO" "Dry run: Skipping files sync from $source_path to $dest_path"
    fi
}

sync_db() {
    local source_path=$1
    local dest_path=$2
    local source_db=$3
    local dest_db=$4
    local source_url=$5
    local dest_url=$6
    if [ "$DRY_RUN" = false ]; then
        log "INFO" "Exporting database from $source_path ($source_db)..."
        wp db export "$TEMP_DIR/db.sql" --path="$source_path" --add-drop-table
        check_status $? "Exporting database from $source_path" "Sync"

        log "INFO" "Importing database to $dest_path ($dest_db)..."
        [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] && mysql -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS $dest_db;"
        wp db import "$TEMP_DIR/db.sql" --path="$dest_path" --dbname="$dest_db"
        check_status $? "Importing database to $dest_path" "Sync"

        log "INFO" "Updating URL from $source_url to $dest_url in $dest_path database..."
        wp search-replace "$source_url" "$dest_url" --path="$dest_path" --all-tables
        check_status $? "Updating URL in $dest_path database" "Sync"

        if [ -z "$stagingDbName" ]; then
            log "INFO" "Updating wp-config.php in $dest_path..."
            cp "$dest_path/wp-config.php" "$dest_path/wp-config.php.bak"
            sed -i "s/define('DB_NAME', '.*');/define('DB_NAME', '$dest_db');/" "$dest_path/wp-config.php"
            check_status $? "Updating wp-config.php in $dest_path" "Sync"
        fi
    else
        log "INFO" "Dry run: Skipping database sync from $source_path to $dest_path"
    fi
}

case "$DIRECTION" in
    push)
        if [ "$SYNC_TYPE" = "files" ] || [ "$SYNC_TYPE" = "both" ]; then
            sync_files "$STAGING_PATH" "$wpPath"
        fi
        if [ "$SYNC_TYPE" = "db" ] || [ "$SYNC_TYPE" = "both" ]; then
            sync_db "$STAGING_PATH" "$wpPath" "$STAGING_DB_NAME" "$DB_NAME" "$STAGING_URL" "$SITE_URL"
        fi
        ;;
    pull)
        if [ "$SYNC_TYPE" = "files" ] || [ "$SYNC_TYPE" = "both" ]; then
            sync_files "$wpPath" "$STAGING_PATH"
        fi
        if [ "$SYNC_TYPE" = "db" ] || [ "$SYNC_TYPE" = "both" ]; then
            sync_db "$wpPath" "$STAGING_PATH" "$DB_NAME" "$STAGING_DB_NAME" "$SITE_URL" "$STAGING_URL"
        fi
        ;;
esac

if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Sync"
else
    log "INFO" "Dry run: Skipping cleanup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
CURRENT_DATE=$(date '+%Y-%m-%d')
log "INFO" "Sync process ($DIRECTION - $SYNC_TYPE) completed successfully in ${DURATION}s"
update_status "SUCCESS" "Sync process ($DIRECTION - $SYNC_TYPE) completed in ${DURATION}s"
notify "SUCCESS" "Sync process ($DIRECTION - $SYNC_TYPE) completed successfully in ${DURATION}s on $CURRENT_DATE" "Sync"

echo "Sync process ($DIRECTION - $SYNC_TYPE) completed!"
echo "Production path: $wpPath"
echo "Staging path: $STAGING_PATH"