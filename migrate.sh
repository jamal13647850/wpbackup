#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/migrate.log"
STATUS_LOG="$SCRIPTPATH/migrate_status.log"
TEMP_DIR="$SCRIPTPATH/temp_migrate"
DIR=$(date +"%Y%m%d-%H%M%S")

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

# Required variables (minimum for local-to-remote migration)
for var in wpPath destinationIP destinationUser destinationPort privateKeyPath destinationWpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

# Optional source server variables (defaults to local if not set)
SOURCE_USER="${sourceUser:-$(whoami)}"
SOURCE_IP="${sourceIP:-localhost}"
SOURCE_PORT="${sourcePort:-22}"
SOURCE_KEY="${sourceKey:-$privateKeyPath}"
SOURCE_WP_PATH="${sourceWpPath:-$wpPath}"
# Optional destination database variables
DEST_DB_NAME="${destDbName:-$(wp config get DB_NAME --path="$wpPath")}"
DEST_DB_USER="${destDbUser:-$(wp config get DB_USER --path="$wpPath")}"
DEST_DB_PASS="${destDbPass:-$(wp config get DB_PASSWORD --path="$wpPath")}"
DEST_WP_URL="${destinationWpUrl}"

LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/backups}"
NICE_LEVEL="${NICE_LEVEL:-19}"
COMPRESSION_FORMAT="${COMPRESSION_FORMAT:-tar.gz}"
DB_FILENAME="db-${DIR}.sql"
FULL_BACKUP_FILENAME="full-${DIR}.${COMPRESSION_FORMAT}"

validate_ssh() {
    local user=$1
    local ip=$2
    local port=$3
    local key=$4
    ssh -p "$port" -i "$key" "$user@$ip" "echo OK" >/dev/null 2>&1
    check_status $? "SSH connection validation to $user@$ip" "Migration"
}

cleanup_migrate() {
    cleanup "Migration process" "Migration"
    rm -rf "$TEMP_DIR"
}
trap cleanup_migrate INT TERM

log "INFO" "Starting migration process from $SOURCE_IP to $destinationIP"
update_status "STARTED" "Migration from $SOURCE_IP to $destinationIP"

# Validate SSH connections
if [ "$SOURCE_IP" != "localhost" ]; then
    validate_ssh "$SOURCE_USER" "$SOURCE_IP" "$SOURCE_PORT" "$SOURCE_KEY"
fi
validate_ssh "$destinationUser" "$destinationIP" "$destinationPort" "$privateKeyPath"
log "INFO" "SSH connections validated successfully"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR"
    check_status $? "Creating temporary directory" "Migration"
else
    log "INFO" "Dry run: Skipping temporary directory creation"
fi

# Step 1: Backup
if [ "$DRY_RUN" = false ]; then
    if [ "$SOURCE_IP" = "localhost" ]; then
        log "INFO" "Backing up local site before migration..."
        bash "$SCRIPTPATH/backup.sh" -c "$CONFIG_FILE" -l
        check_status $? "Local backup before migration" "Migration"
        wp db export "$TEMP_DIR/$DB_FILENAME" --add-drop-table --path="$SOURCE_WP_PATH"
        check_status $? "Exporting local database" "Migration"
    else
        log "INFO" "Backing up database from source server..."
        ssh -p "$SOURCE_PORT" -i "$SOURCE_KEY" "$SOURCE_USER@$SOURCE_IP" \
            "wp db export $DB_FILENAME --path=$SOURCE_WP_PATH --add-drop-table"
        check_status $? "Exporting database from source" "Migration"
        rsync -azvrh --progress -e "ssh -p $SOURCE_PORT -i $SOURCE_KEY" \
            "$SOURCE_USER@$SOURCE_IP:$DB_FILENAME" "$TEMP_DIR/"
        check_status $? "Downloading database backup to temp directory" "Migration"
        ssh -p "$SOURCE_PORT" -i "$SOURCE_KEY" "$SOURCE_USER@$SOURCE_IP" \
            "rm -f $DB_FILENAME"
    fi

    log "INFO" "Compressing database backup..."
    compress "$TEMP_DIR/$DB_FILENAME" "$TEMP_DIR/db-${DIR}.${COMPRESSION_FORMAT}" "Migration"
    rm -f "$TEMP_DIR/$DB_FILENAME"
else
    log "INFO" "Dry run: Skipping backup"
fi

# Step 2: Transfer
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Transferring backups to destination server..."
    rsync -azvrh --progress -e "ssh -p $destinationPort -i $privateKeyPath" \
        "$TEMP_DIR/db-${DIR}.${COMPRESSION_FORMAT}" "$destinationUser@$destinationIP:$destinationWpPath/"
    check_status $? "Transferring database to destination" "Migration"
    rsync -azvrh --progress -e "ssh -p $destinationPort -i $privateKeyPath" \
        "$SOURCE_WP_PATH/" "$destinationUser@$destinationIP:$destinationWpPath/"
    check_status $? "Transferring files to destination" "Migration"
else
    log "INFO" "Dry run: Skipping transfer"
fi

# Step 3: Restore on destination
if [ "$DRY_RUN" = false ]; then
    log "INFO" "Restoring on destination server..."
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" \
        "mysql -u root -e \"CREATE DATABASE IF NOT EXISTS $DEST_DB_NAME; GRANT ALL PRIVILEGES ON $DEST_DB_NAME.* TO '$DEST_DB_USER'@'localhost' IDENTIFIED BY '$DEST_DB_PASS'; FLUSH PRIVILEGES;\""
    check_status $? "Creating database on destination" "Migration"

    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" << EOF
        cd "$destinationWpPath"
        tar -xzf db-${DIR}.${COMPRESSION_FORMAT} || unzip db-${DIR}.zip || tar -xf db-${DIR}.tar
        wp db import $DB_FILENAME --path="$destinationWpPath"
        rm -f $DB_FILENAME db-${DIR}.${COMPRESSION_FORMAT}
EOF
    check_status $? "Importing database on destination" "Migration"

    if [ -z "$DEST_WP_URL" ]; then
        read -p "Enter the new site URL (e.g., http://newdomain.com): " NEW_URL
        DEST_WP_URL="$NEW_URL"
    fi
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" \
        "wp search-replace '$(wp option get siteurl --path=$destinationWpPath)' '$DEST_WP_URL' --path=$destinationWpPath --all-tables"
    check_status $? "Updating site URL" "Migration"
else
    log "INFO" "Dry run: Skipping restoration"
fi

# Cleanup
if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Migration"
else
    log "INFO" "Dry run: Skipping cleanup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
CURRENT_DATE=$(date '+%Y-%m-%d')
log "INFO" "Migration completed successfully in ${DURATION}s"
update_status "SUCCESS" "Migration from $SOURCE_IP to $destinationIP in ${DURATION}s"
notify "SUCCESS" "Migration from $SOURCE_IP to $destinationIP completed successfully in ${DURATION}s on $CURRENT_DATE" "Migration"

echo "Migration complete! Check the new site at $DEST_WP_URL"