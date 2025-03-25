#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/cron-scheduler.log"
STATUS_LOG="$SCRIPTPATH/cron-scheduler_status.log"

setup_cron() {
    local config_file="$1"
    local project_name=$(basename "$config_file" .conf)
    local dry_run="${2:-false}"
    local verbose="${3:-false}"
    local compression="${4:-tar.gz}"
    local location="${5:-b}"

    echo "Setting up cron jobs for $project_name..."
    echo "Select backup frequency:"
    echo "1) Daily (2 AM)"
    echo "2) Every 12 hours (2 AM, 2 PM)"
    echo "3) Every 6 hours (2 AM, 8 AM, 2 PM, 8 PM)"
    echo "4) Every 4 hours"
    echo "5) Weekly (Sunday 2 AM)"
    echo "6) Monthly (1st 2 AM)"
    read -p "Enter choice (1-6): " FREQUENCY

    echo "Select backup type:"
    echo "1) Full (database + files)"
    echo "2) Database only"
    echo "3) Files only"
    read -p "Enter choice (1-3): " BACKUP_TYPE

    local cron_cmd=""
    local script_cmd=""
    case $BACKUP_TYPE in
        1) script_cmd="$SCRIPTPATH/backup.sh -c $config_file -f $compression";;
        2) script_cmd="$SCRIPTPATH/database.sh -c $config_file -f $compression";;
        3) script_cmd="$SCRIPTPATH/files.sh -c $config_file -f $compression";;
        *) log "ERROR" "Invalid backup type"; exit 1;;
    esac

    case $location in
        l) script_cmd="$script_cmd -l";;
        r) script_cmd="$script_cmd -r";;
        b) script_cmd="$script_cmd -b";;
        *) log "ERROR" "Invalid backup location"; exit 1;;
    esac

    [ "$dry_run" = "true" ] && script_cmd="$script_cmd -d"
    [ "$verbose" = "true" ] && script_cmd="$script_cmd -v"

    case $FREQUENCY in
        1) cron_cmd="0 2 * * * /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        2) cron_cmd="0 2,14 * * * /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        3) cron_cmd="0 2,8,14,20 * * * /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        4) cron_cmd="0 */4 * * * /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        5) cron_cmd="0 2 * * 0 /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        6) cron_cmd="0 2 1 * * /bin/bash $script_cmd >> $SCRIPTPATH/backup.log 2>&1";;
        *) log "ERROR" "Invalid frequency"; exit 1;;
    esac

    if [ "$dry_run" = "false" ]; then
        (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
        check_status $? "Setting up cron job for $project_name" "CronScheduler"
    fi
    log "INFO" "Cron job scheduled for $project_name: $cron_cmd"
    echo "Cron job: $cron_cmd"
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <config_file> [dry_run] [verbose] [compression] [location]"
    exit 1
fi

CONFIG_FILE="$1"
DRY_RUN="${2:-false}"
VERBOSE="${3:-false}"
COMPRESSION="${4:-tar.gz}"
LOCATION="${5:-b}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE not found!" >&2
    exit 1
fi

eval "$(load_config "$CONFIG_FILE")"
setup_cron "$CONFIG_FILE" "$DRY_RUN" "$VERBOSE" "$COMPRESSION" "$LOCATION"