#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/setup.log"
STATUS_LOG="$SCRIPTPATH/setup_status.log"

install_prerequisites() {
    log "INFO" "Checking and installing prerequisites..."

    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        UPDATE_CMD="apt update -y"
        INSTALL_CMD="apt install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        UPDATE_CMD="yum update -y"
        INSTALL_CMD="yum install -y"
    else
        log "ERROR" "Unsupported package manager!"
        exit 1
    fi

    $UPDATE_CMD
    check_status $? "Updating package list" "Setup"

    PACKAGES="rsync mailutils curl pigz unzip zip mysql-client"
    for pkg in $PACKAGES; do
        if ! command -v "$pkg" >/dev/null 2>&1 && [ "$pkg" != "mailutils" ] && [ "$pkg" != "mysql-client" ]; then
            $INSTALL_CMD "$pkg"
            check_status $? "Installing $pkg" "Setup"
        elif [ "$pkg" = "mailutils" ] && ! command -v mail >/dev/null 2>&1; then
            $INSTALL_CMD "$pkg"
            check_status $? "Installing $pkg" "Setup"
        elif [ "$pkg" = "mysql-client" ] && ! command -v mysql >/dev/null 2>&1; then
            $INSTALL_CMD "$pkg"
            check_status $? "Installing $pkg" "Setup"
        else
            log "DEBUG" "$pkg is already installed."
        fi
    done

    if ! command -v wp >/dev/null 2>&1; then
        log "INFO" "Installing WP-CLI..."
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        check_status $? "Installing WP-CLI" "Setup"
    fi
}

create_backup_config() {
    local configs_created=()
    while true; do
        read -p "Enter project name: " PROJECT_NAME
        read -p "Enter WordPress path: " WP_PATH
        read -p "Enter SSH user: " SSH_USER
        read -p "Enter SSH IP: " SSH_IP
        read -p "Enter SSH port (default 22): " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}
        read -p "Enter SSH private key path: " SSH_KEY
        read -p "Enter remote DB backup path: " DB_BACKUP_PATH
        read -p "Enter remote files backup path: " FILES_BACKUP_PATH
        read -p "Enter local full backup path: " FULL_PATH
        read -p "Enter retention duration (days, default 10): " RETAIN_DURATION
        RETAIN_DURATION=${RETAIN_DURATION:-10}
        read -p "Enter max file size (default 50m): " MAX_SIZE
        MAX_SIZE=${MAX_SIZE:-50m}
        read -p "Enter compression format (default tar.gz): " COMPRESSION_FORMAT
        COMPRESSION_FORMAT=${COMPRESSION_FORMAT:-tar.gz}
        read -p "Enter notification method(s): " NOTIFY_METHOD
        if [[ "$NOTIFY_METHOD" =~ "email" ]]; then
            read -p "Enter email: " NOTIFY_EMAIL
        fi
        if [[ "$NOTIFY_METHOD" =~ "slack" ]]; then
            read -p "Enter Slack webhook URL: " SLACK_WEBHOOK_URL
        fi
        if [[ "$NOTIFY_METHOD" =~ "telegram" ]]; then
            read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
            read -p "Enter Telegram chat ID: " TELEGRAM_CHAT_ID
        fi

        mkdir -p "$SCRIPTPATH/configs"
        check_status $? "Creating configs directory" "Setup"

        CONFIG_FILE="$SCRIPTPATH/configs/$PROJECT_NAME.conf"
        cat << EOF > "$CONFIG_FILE"
destinationPort=$SSH_PORT
destinationUser="$SSH_USER"
destinationIP="$SSH_IP"
destinationDbBackupPath="$DB_BACKUP_PATH"
destinationFilesBackupPath="$FILES_BACKUP_PATH"
privateKeyPath="$SSH_KEY"
wpPath="$WP_PATH"
maxSize="$MAX_SIZE"
fullPath="$FULL_PATH"
BACKUP_RETAIN_DURATION=$RETAIN_DURATION
NICE_LEVEL=19
COMPRESSION_FORMAT="$COMPRESSION_FORMAT"
LOG_LEVEL="normal"
BACKUP_LOCATION="both"
NOTIFY_METHOD="$NOTIFY_METHOD"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
EOF
        chmod 600 "$CONFIG_FILE"
        check_status $? "Creating config $CONFIG_FILE" "Setup"
        configs_created+=("$CONFIG_FILE")

        read -p "Add another project? (y/n): " ADD_ANOTHER
        [ "$ADD_ANOTHER" != "y" ] && break
    done
    printf '%s\n' "${configs_created[@]}"
}

create_migration_config() {
    local migrate_configs_created=()
    read -p "Set up migration? (y/n): " SETUP_MIGRATION
    if [ "$SETUP_MIGRATION" = "y" ]; then
        while true; do
            read -p "Enter migration project name: " MIGRATE_NAME
            read -p "Enter source SSH user: " SOURCE_USER
            read -p "Enter source SSH IP: " SOURCE_IP
            read -p "Enter source SSH port (default 22): " SOURCE_PORT
            SOURCE_PORT=${SOURCE_PORT:-22}
            read -p "Enter source SSH key path: " SOURCE_KEY
            read -p "Enter source WordPress path: " SOURCE_WP_PATH
            read -p "Enter destination SSH user: " DEST_USER
            read -p "Enter destination SSH IP: " DEST_IP
            read -p "Enter destination SSH port (default 22): " DEST_PORT
            DEST_PORT=${DEST_PORT:-22}
            read -p "Enter destination SSH key path: " DEST_KEY
            read -p "Enter destination WordPress path: " DEST_WP_PATH
            read -p "Enter destination DB name: " DEST_DB_NAME
            read -p "Enter destination DB user: " DEST_DB_USER
            read -p "Enter destination DB password: " DEST_DB_PASS
            read -p "Enter notification method(s): " NOTIFY_METHOD
            if [[ "$NOTIFY_METHOD" =~ "email" ]]; then
                read -p "Enter email: " NOTIFY_EMAIL
            fi
            if [[ "$NOTIFY_METHOD" =~ "slack" ]]; then
                read -p "Enter Slack webhook URL: " SLACK_WEBHOOK_URL
            fi
            if [[ "$NOTIFY_METHOD" =~ "telegram" ]]; then
                read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
                read -p "Enter Telegram chat ID: " TELEGRAM_CHAT_ID
            fi

            mkdir -p "$SCRIPTPATH/configs"
            check_status $? "Creating configs directory" "Setup"

            MIGRATE_CONFIG_FILE="$SCRIPTPATH/configs/$MIGRATE_NAME.conf"
            cat << EOF > "$MIGRATE_CONFIG_FILE"
sourceUser="$SOURCE_USER"
sourceIP="$SOURCE_IP"
sourcePort=$SOURCE_PORT
sourceKey="$SOURCE_KEY"
sourceWpPath="$SOURCE_WP_PATH"
destUser="$DEST_USER"
destIP="$DEST_IP"
destPort=$DEST_PORT
destKey="$DEST_KEY"
destWpPath="$DEST_WP_PATH"
destDbName="$DEST_DB_NAME"
destDbUser="$DEST_DB_USER"
destDbPass="$DEST_DB_PASS"
NOTIFY_METHOD="$NOTIFY_METHOD"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
EOF
            chmod 600 "$MIGRATE_CONFIG_FILE"
            check_status $? "Creating migration config $MIGRATE_CONFIG_FILE" "Setup"
            migrate_configs_created+=("$MIGRATE_CONFIG_FILE")

            read -p "Add another migration? (y/n): " ADD_ANOTHER
            [ "$ADD_ANOTHER" != "y" ] && break
        done
    fi
    printf '%s\n' "${migrate_configs_created[@]}"
}

install_gravity_forms() {
    read -p "Install Gravity Forms CLI? (y/n): " INSTALL_GF
    if [ "$INSTALL_GF" = "y" ]; then
        log "INFO" "Installing Gravity Forms CLI..."
        wp package install wp-cli/gravityforms-cli --path="$WP_PATH" 2>/dev/null
        check_status $? "Installing Gravity Forms CLI" "Setup"
    fi
}

log "INFO" "Starting setup process..."
update_status "STARTED" "Setup process"

install_prerequisites
configs=$(create_backup_config)
migrate_configs=$(create_migration_config)
install_gravity_forms

log "INFO" "Setup completed successfully!"
update_status "SUCCESS" "Setup process completed"
notify "SUCCESS" "Setup process completed successfully" "Setup"

echo "Setup complete!"
echo "Backup configs created:"
printf '%s\n' "${configs[@]}"
echo "Migration configs created:"
printf '%s\n' "${migrate_configs[@]}"