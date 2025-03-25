#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/wp-tools.log"
STATUS_LOG="$SCRIPTPATH/wp-tools_status.log"

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
RESET=$(tput sgr0)

show_menu() {
    clear
    echo "${BLUE}${BOLD}=====================================${RESET}"
    echo "${GREEN}${BOLD} WordPress Tools - Interactive Menu ${RESET}"
    echo "${BLUE}${BOLD}=====================================${RESET}"
    echo "1. ${YELLOW}Setup${RESET} (Install prerequisites and create configs)"
    echo "2. ${YELLOW}Backup${RESET} (Database and/or Files)"
    echo "3. ${YELLOW}Restore${RESET} (From a backup)"
    echo "4. ${YELLOW}Migrate${RESET} (Move site to another server)"
    echo "5. ${YELLOW}Create Staging${RESET} Environment"
    echo "6. ${YELLOW}Sync${RESET} (Push/Pull between Staging and Production)"
    echo "7. ${YELLOW}Schedule Cron Jobs${RESET} (Automate tasks)"
    echo "8. ${YELLOW}Exit${RESET}"
    echo "${BLUE}${BOLD}=====================================${RESET}"
    echo -n "${GREEN}Enter your choice (1-8): ${RESET}"
}

get_config_file() {
    local config_dir="$SCRIPTPATH/configs"
    echo "${BLUE}Available config files in $config_dir:${RESET}"
    local configs=("$config_dir"/*.conf "$config_dir"/*.conf.gpg)
    if [ ${#configs[@]} -eq 0 ] || [ ! -e "${configs[0]}" ]; then
        echo "${RED}No config files found! Please run Setup first.${RESET}"
        return 1
    fi
    ls -1 "$config_dir"/*.{conf,conf.gpg} 2>/dev/null | while read -r file; do echo " - $(basename "$file")"; done
    echo -n "${GREEN}Enter the config file name (e.g., project1.conf or project1.conf.gpg) or full path: ${RESET}"
    read config
    if [[ -z "$config" ]]; then
        echo "${RED}Error: No config file specified!${RESET}"
        return 1
    fi
    if [[ ! "$config" =~ \.(conf|conf\.gpg)$ ]]; then
        if [ -f "$config_dir/$config.conf.gpg" ]; then
            config="$config.conf.gpg"
        else
            config="$config.conf"
        fi
    fi
    if [[ "$config" =~ ^/ ]]; then
        CONFIG_FILE="$config"
    else
        CONFIG_FILE="$config_dir/$config"
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "${RED}Error: Config file $CONFIG_FILE not found!${RESET}"
        return 1
    fi
    if [[ "$CONFIG_FILE" =~ \.gpg$ ]]; then
        echo -n "${GREEN}Enter passphrase for $CONFIG_FILE (leave blank if using ~/.gpg-passphrase): ${RESET}"
        read -s passphrase
        echo
        export CONFIG_PASSPHRASE="$passphrase"
    else
        export CONFIG_PASSPHRASE=""
    fi
    return 0
}

get_common_options() {
    echo -n "${GREEN}Run in Dry Run mode (test only, no changes)? (y/n, default: n): ${RESET}"
    read dry_run
    DRY_RUN="false"
    [ "$dry_run" = "y" ] && DRY_RUN="true"

    echo -n "${GREEN}Enable Verbose logging? (y/n, default: n): ${RESET}"
    read verbose
    VERBOSE="false"
    [ "$verbose" = "y" ] && VERBOSE="true"
}

get_compression_format() {
    echo "${BLUE}Available compression formats:${RESET}"
    echo "1. zip"
    echo "2. tar.gz"
    echo "3. tar"
    echo -n "${GREEN}Choose compression format (1-3, default: zip): ${RESET}"
    read format_choice
    COMPRESSION="zip"
    case "$format_choice" in
        1|"") COMPRESSION="zip" ;;
        2) COMPRESSION="tar.gz" ;;
        3) COMPRESSION="tar" ;;
        *) echo "${YELLOW}Invalid choice! Defaulting to zip.${RESET}" ;;
    esac
}

run_setup() {
    echo "${BLUE}Running Setup...${RESET}"
    local cmd="$SCRIPTPATH/setup.sh"
    echo "Executing: $cmd"
    eval "$cmd"
}

run_backup() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping backup due to config error.${RESET}"
        return
    fi
    get_common_options
    get_compression_format
    echo "${BLUE}Backup Options:${RESET}"
    echo "1. Full Backup (Database + Files)"
    echo "2. Incremental Files Backup (Database full)"
    echo "3. Files Only"
    echo -n "${GREEN}Choose backup type (1-3): ${RESET}"
    read backup_type
    echo -n "${GREEN}Store backup locally (l), remotely (r), or both (b)? (l/r/b): ${RESET}"
    read location

    local cmd=""
    case "$backup_type" in
        1) cmd="$SCRIPTPATH/backup.sh -c $CONFIG_FILE" ;;
        2) cmd="$SCRIPTPATH/backup.sh -c $CONFIG_FILE -i" ;;
        3) cmd="$SCRIPTPATH/files.sh -c $CONFIG_FILE" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac
    case "$location" in
        l) cmd="$cmd -l" ;;
        r) cmd="$cmd -r" ;;
        b) cmd="$cmd -b" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac
    [ "$DRY_RUN" = "true" ] && cmd="$cmd -d"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"
    cmd="$cmd -f $COMPRESSION"

    echo "Running: $cmd"
    eval "$cmd"
}

run_restore() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping restore due to config error.${RESET}"
        return
    fi
    get_common_options
    echo "${BLUE}Restore Options:${RESET}"
    echo "1. Restore Database"
    echo "2. Restore Files (Full or Incremental)"
    echo "3. Restore Both"
    echo -n "${GREEN}Choose restore type (1-3): ${RESET}"
    read restore_type
    echo -n "${GREEN}Use latest backup? (y/n, default: n): ${RESET}"
    read latest

    local cmd="$SCRIPTPATH/restore.sh -c $CONFIG_FILE"
    case "$restore_type" in
        1) cmd="$cmd -r db" ;;
        2) 
            echo -n "${GREEN}Restore incrementally? (y/n, default: n): ${RESET}"
            read incremental
            cmd="$cmd -r files"
            [ "$incremental" = "y" ] && cmd="$cmd -i"
            ;;
        3) cmd="$cmd -r both" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac
    [ "$latest" = "y" ] && cmd="$cmd -l"
    [ "$DRY_RUN" = "true" ] && cmd="$cmd -d"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"

    echo "Running: $cmd"
    eval "$cmd"
}

run_migrate() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping migration due to config error.${RESET}"
        return
    fi
    get_common_options
    local cmd="$SCRIPTPATH/migrate.sh -c $CONFIG_FILE"
    [ "$DRY_RUN" = "true" ] && cmd="$cmd -d"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"
    echo "Running: $cmd"
    eval "$cmd"
}

run_staging() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping staging due to config error.${RESET}"
        return
    fi
    get_common_options
    local cmd="$SCRIPTPATH/staging.sh -c $CONFIG_FILE"
    [ "$DRY_RUN" = "true" ] && cmd="$cmd -d"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"
    echo "Running: $cmd"
    eval "$cmd"
}

run_sync() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping sync due to config error.${RESET}"
        return
    fi
    get_common_options
    echo "${BLUE}Sync Options:${RESET}"
    echo "1. Push (Staging → Production)"
    echo "2. Pull (Production → Staging)"
    echo -n "${GREEN}Choose direction (1-2): ${RESET}"
    read direction
    echo "${BLUE}Sync Type:${RESET}"
    echo "1. Database"
    echo "2. Files"
    echo "3. Both"
    echo -n "${GREEN}Choose sync type (1-3): ${RESET}"
    read sync_type

    local cmd="$SCRIPTPATH/sync.sh -c $CONFIG_FILE"
    case "$direction" in
        1) cmd="$cmd -d push" ;;
        2) cmd="$cmd -d pull" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac
    case "$sync_type" in
        1) cmd="$cmd -t db" ;;
        2) cmd="$cmd -t files" ;;
        3) cmd="$cmd -t both" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac
    [ "$DRY_RUN" = "true" ] && cmd="$cmd -d"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"

    echo "Running: $cmd"
    eval "$cmd"
}

run_cron_scheduler() {
    if ! get_config_file; then
        echo "${YELLOW}Skipping cron scheduling due to config error.${RESET}"
        return
    fi
    get_common_options
    get_compression_format
    echo -n "${GREEN}Store backup locally (l), remotely (r), or both (b)? (l/r/b): ${RESET}"
    read location

    local cmd="$SCRIPTPATH/cron-scheduler.sh $CONFIG_FILE $DRY_RUN $VERBOSE $COMPRESSION"
    case "$location" in
        l) cmd="$cmd l" ;;
        r) cmd="$cmd r" ;;
        b) cmd="$cmd b" ;;
        *) echo "${RED}Invalid choice! Returning to menu.${RESET}"; return ;;
    esac

    echo "Running: $cmd"
    eval "$cmd"
}

while true; do
    show_menu
    read choice
    case $choice in
        1) run_setup ;;
        2) run_backup ;;
        3) run_restore ;;
        4) run_migrate ;;
        5) run_staging ;;
        6) run_sync ;;
        7) run_cron_scheduler ;;
        8) 
            echo "${GREEN}Exiting WordPress Tools. Goodbye!${RESET}"
            exit 0
            ;;
        *) echo "${RED}Invalid choice! Please select 1-8.${RESET}" ;;
    esac
    echo -n "${BLUE}Press Enter to continue...${RESET}"
    read
done