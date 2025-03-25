#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. "$SCRIPTPATH/common.sh"

LOG_FILE="$SCRIPTPATH/restore.log"
STATUS_LOG="$SCRIPTPATH/restore_status.log"
TEMP_DIR="$SCRIPTPATH/temp_restore"
LAST_BACKUP_FILE="$SCRIPTPATH/last_backup.txt"
DIR=$(date +"%Y%m%d-%H%M%S")

DRY_RUN=false
LATEST=false
NON_INTERACTIVE=false
BACKUP_BEFORE=false
VERBOSE=false
RESTORE_TYPE=""
PARTIAL_PATTERN=""
BACKUP_FILE=""
INCREMENTAL=false
while getopts "c:r:ldnb:f:p:iv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        r) RESTORE_TYPE="$OPTARG";;
        l) LATEST=true;;
        d) DRY_RUN=true;;
        n) NON_INTERACTIVE=true;;
        b) BACKUP_BEFORE=true;;
        f) BACKUP_FILE="$OPTARG";;
        p) PARTIAL_PATTERN="$OPTARG";;
        i) INCREMENTAL=true;;
        v) VERBOSE=true;;
        ?) echo "Usage: $0 -c <config_file> [-r <db|files|both|partial>] [-l] [-d] [-n] [-b] [-f <backup_file>] [-p <pattern>] [-i] [-v]" >&2; exit 1;;
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

for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE!" >&2
        exit 1
    fi
done

BACKUP_DIR="${BACKUP_DIR:-$SCRIPTPATH/restores}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPTPATH/local_backups}"
NICE_LEVEL="${NICE_LEVEL:-19}"
COMPRESSION_FORMAT="${COMPRESSION_FORMAT:-tar.gz}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"
destinationPort="${destinationPort:-22}"

validate_ssh() {
    if [ -n "$destinationIP" ]; then
        ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "echo OK" >/dev/null 2>&1
        check_status $? "SSH connection validation" "Restore"
    fi
}

cleanup_restore() {
    cleanup "Restore process" "Restore"
    rm -rf "$TEMP_DIR"
}
trap cleanup_restore INT TERM

log "INFO" "Starting restore process for $DIR (Incremental Files: $INCREMENTAL)"
update_status "STARTED" "Restore process for $DIR"

validate_ssh
log "INFO" "SSH connection validated successfully (if applicable)"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$TEMP_DIR"
    check_status $? "Creating temporary directory $TEMP_DIR" "Restore"
else
    log "INFO" "Dry run: Skipping directory creation"
fi

if [ "$BACKUP_BEFORE" = true ] && [ "$DRY_RUN" = false ]; then
    log "INFO" "Backing up current state before restore"
    bash "$SCRIPTPATH/backup.sh" -c "$CONFIG_FILE" -l
    check_status $? "Backup of current state" "Restore"
elif [ "$BACKUP_BEFORE" = true ]; then
    log "INFO" "Dry run: Would backup current state before restore"
fi

get_latest_backup() {
    local type=$1
    local path=""
    [ "$type" = "db" ] && path="$destinationDbBackupPath" || path="$destinationFilesBackupPath"
    ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "ls -t $path/*.{zip,tar.gz,tar} 2>/dev/null | head -n 1" | awk -F'/' '{print $NF}'
}

list_backups() {
    local type=$1
    local source=$2
    local path=""
    local -a backups=()

    if [ "$source" = "remote" ] && [ -n "$destinationIP" ]; then
        [ "$type" = "db" ] && path="$destinationDbBackupPath" || path="$destinationFilesBackupPath"
        mapfile -t backups < <(ssh -p "$destinationPort" -i "$privateKeyPath" "$destinationUser@$destinationIP" "ls -t $path/*.{zip,tar.gz,tar} 2>/dev/null" | awk -F'/' '{print $NF}')
    else
        [ "$type" = "db" ] && path="$LOCAL_BACKUP_DIR" || path="$LOCAL_BACKUP_DIR"
        mapfile -t backups < <(find "$path" -maxdepth 1 -type f -name "${DB_FILE_PREFIX:-DB}-*.{zip,tar.gz,tar}" 2>/dev/null | sort -r)
        [ "$type" = "files" ] && mapfile -t backups < <(find "$path" -maxdepth 1 -type f -name "${FILES_FILE_PREFIX:-Files}-*.{zip,tar.gz,tar}" 2>/dev/null | sort -r)
    fi

    if [ ${#backups[@]} -eq 0 ]; then
        log "INFO" "No $type backups found in $source ($path)"
        return 1
    fi

    echo "Available $type backups in $source ($path):"
    for i in "${!backups[@]}"; do
        echo "[$i] ${backups[$i]}"
    done
    return 0
}

select_backup() {
    local type=$1
    local -a selected_backups=()

    read -p "List backups from local or remote? (l/r): " source
    if [ "$source" = "l" ]; then
        source="local"
    elif [ "$source" = "r" ] && [ -n "$destinationIP" ]; then
        source="remote"
    else
        log "ERROR" "Invalid input, please enter l or r (remote requires destinationIP)"
        select_backup "$type"
        return
    fi

    list_backups "$type" "$source" || return 1
    read -p "Enter the number(s) of the backup(s) to restore (comma-separated for multiple, or 'all' for incremental chain): " selections
    if [ "$selections" = "all" ] && [ "$type" = "files" ] && [ "$INCREMENTAL" = true ]; then
        selected_backups=("${backups[@]}")
        log "INFO" "Selected all $type backups for incremental restore: ${selected_backups[*]}"
    else
        IFS=',' read -ra selection_array <<< "$selections"
        for selection in "${selection_array[@]}"; do
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -lt "${#backups[@]}" ]; then
                selected_backups+=("${backups[$selection]}")
                log "INFO" "Selected $type backup: ${backups[$selection]} from $source"
            else
                log "ERROR" "Invalid selection: $selection, please enter valid numbers or 'all'"
                select_backup "$type"
                return
            fi
        done
    fi

    if [ "$type" = "db" ]; then
        dbfilename="${selected_backups[*]}"
        [ "$source" = "local" ] && dbfilename="$LOCAL_BACKUP_DIR/$(basename "${selected_backups[0]}")"
    else
        filesfilename=("${selected_backups[@]}")
        [ "$source" = "local" ] && for i in "${!filesfilename[@]}"; do filesfilename[$i]="$LOCAL_BACKUP_DIR/$(basename "${filesfilename[$i]}")"; done
    fi
}

download_file() {
    local source_path=$1
    local dest_path="$TEMP_DIR/$(basename "$source_path")"
    if [ "$DRY_RUN" = false ]; then
        if [[ "$source_path" =~ ^/ ]]; then
            cp -v "$source_path" "$dest_path"
            check_status $? "Copying from local $source_path" "Restore"
        elif [ -n "$destinationIP" ]; then
            rsync -azvrh --progress -e "ssh -p $destinationPort -i $privateKeyPath" \
                "$destinationUser@$destinationIP:$source_path" "$dest_path"
            check_status $? "Downloading from $source_path" "Restore"
        fi
    else
        log "INFO" "Dry run: Skipping download/copy from $source_path"
    fi
    echo "$dest_path"
}

restore_process() {
    local db_file=""
    local -a files_files=()

    if [ -n "$BACKUP_FILE" ]; then
        if [ "$DRY_RUN" = false ]; then
            download_file "$BACKUP_FILE"
            BACKUP_FILE="$TEMP_DIR/$(basename "$BACKUP_FILE")"
            decompress "$BACKUP_FILE" "$TEMP_DIR" "Restore"
            db_file=$(find "$TEMP_DIR" -name "*.sql" | head -n 1)
            files_files=($(find "$TEMP_DIR" -type d -name "files"))
        fi
    else
        if [ "$NON_INTERACTIVE" = true ]; then
            if [ "$LATEST" = true ]; then
                [ "$RESTORE_TYPE" = "db" ] || [ "$RESTORE_TYPE" = "both" ] && dbfilename=$(get_latest_backup "db")
                [ "$RESTORE_TYPE" = "files" ] || [ "$RESTORE_TYPE" = "both" ] || [ "$RESTORE_TYPE" = "partial" ] && filesfilename=($(get_latest_backup "files"))
            fi
        elif [ -z "$RESTORE_TYPE" ]; then
            read -p "Which do you intend to restore? (db/files/both/partial): " RESTORE_TYPE
        fi

        case "$RESTORE_TYPE" in
            db)
                if [ "$NON_INTERACTIVE" = false ]; then
                    select_backup "db"
                fi
                db_file=$(download_file "$destinationDbBackupPath/$dbfilename")
                ;;
            files|partial)
                if [ "$NON_INTERACTIVE" = false ]; then
                    select_backup "files"
                fi
                for file in "${filesfilename[@]}"; do
                    files_files+=($(download_file "$destinationFilesBackupPath/$file"))
                done
                ;;
            both)
                if [ "$NON_INTERACTIVE" = false ]; then
                    select_backup "db"
                    select_backup "files"
                fi
                db_file=$(download_file "$destinationDbBackupPath/$dbfilename")
                for file in "${filesfilename[@]}"; do
                    files_files+=($(download_file "$destinationFilesBackupPath/$file"))
                done
                ;;
            *)
                log "ERROR" "Invalid restore type: $RESTORE_TYPE (use db, files, both, or partial)"
                exit 1
                ;;
        esac

        if [ "$DRY_RUN" = false ]; then
            [ -n "$db_file" ] && decompress "$db_file" "$TEMP_DIR" "Restore" && db_file=$(find "$TEMP_DIR" -name "*.sql" | head -n 1)
            for file in "${files_files[@]}"; do
                decompress "$file" "$TEMP_DIR" "Restore"
            done
            files_files=($(find "$TEMP_DIR" -type d -name "files"))
        fi
    fi

    if { [ "$RESTORE_TYPE" = "db" ] || [ "$RESTORE_TYPE" = "both" ] || [ -z "$RESTORE_TYPE" ]; } && [ -n "$db_file" ]; then
        if [ "$DRY_RUN" = false ]; then
            log "INFO" "Restoring database..."
            wp db import "$db_file" --path="$wpPath"
            check_status $? "Importing database" "Restore"
        else
            log "INFO" "Dry run: Skipping database restore"
        fi
    fi

    if { [ "$RESTORE_TYPE" = "files" ] || [ "$RESTORE_TYPE" = "both" ] || [ "$RESTORE_TYPE" = "partial" ] || [ -z "$RESTORE_TYPE" ]; } && [ ${#files_files[@]} -gt 0 ]; then
        if [ "$DRY_RUN" = false ]; then
            if [ "$INCREMENTAL" = true ] && [ "$RESTORE_TYPE" != "partial" ]; then
                log "INFO" "Restoring incremental chain of files..."
                for file_dir in "${files_files[@]}"; do
                    rsync -azvrh --progress "$file_dir/" "$wpPath/"
                    check_status $? "Restoring incremental files from $file_dir" "Restore"
                done
            elif [ "$RESTORE_TYPE" = "partial" ] && [ -n "$PARTIAL_PATTERN" ]; then
                log "INFO" "Restoring partial files matching pattern: $PARTIAL_PATTERN..."
                rsync -azvrh --progress --include="$PARTIAL_PATTERN" --exclude="*" "${files_files[0]}/" "$wpPath/"
                check_status $? "Restoring partial files" "Restore"
            else
                log "INFO" "Restoring full files from latest backup..."
                rsync -azvrh --progress "${files_files[0]}/" "$wpPath/"
                check_status $? "Restoring full files" "Restore"
            fi
        else
            log "INFO" "Dry run: Skipping files restore"
        fi
    fi
}

restore_process

if [ "$DRY_RUN" = false ]; then
    rm -rf "$TEMP_DIR"
    check_status $? "Cleaning up temporary directory" "Restore"
else
    log "INFO" "Dry run: Skipping cleanup"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Restore process completed successfully in ${DURATION}s"
update_status "SUCCESS" "Restore process completed in ${DURATION}s"
notify "SUCCESS" "Restore process completed successfully in ${DURATION}s" "Restore"

echo "Restore complete! Check your site at $wpPath"