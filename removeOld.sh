#!/bin/bash
# removeOld.sh - Script to remove old backup files and logs

. "$(dirname "$0")/common.sh"

# Default values
SAFE_PATHS=("/var/backups" "/home/backup" "$SCRIPTPATH/backups")
ARCHIVE_EXTS=("zip" "tar" "tar.gz" "tgz" "gz" "bz2" "xz" "7z")
LOG_FILE="$SCRIPTPATH/remove_old.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/remove_old_status.log}"
MAX_LOG_SIZE=$((200*1024*1024))
DRY_RUN=false
VERBOSE=false

function usage() {
    echo -e "${GREEN}Usage: $0 -c <config_file> [-d] [-v] [--help]${NC}"
    echo -e "  -c <config_file>   Path to config file"
    echo -e "  -d                 Dry run (do not actually delete, just print list)"
    echo -e "  -v                 Verbose output"
    echo -e "  --help             Show this help"
    exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) CONFIG_FILE="$2"; shift 2;;
        -d) DRY_RUN=true; shift;;
        -v) VERBOSE=true; shift;;
        --help|-h) usage;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage;;
    esac
done

# Check if config file is specified and exists
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not specified! Use -c <config_file>${NC}" >&2
    exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    . "$CONFIG_FILE"
fi

# Check required variables
for var in fullPath BACKUP_RETAIN_DURATION; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Check if path is in safe paths
FOUND_SAFE=0
for dir in "${SAFE_PATHS[@]}"; do
    [[ "$fullPath" == $dir* ]] && FOUND_SAFE=1
done
if [ "$FOUND_SAFE" -ne 1 ]; then
    echo -e "${RED}Error: The path $fullPath is not in allowed (safe) paths.${NC}"
    exit 2
fi

# Set default values
NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-${LOG_LEVEL:-normal}}"

# Use a lock file to prevent multiple instances
LOCK_FILE="/var/lock/removeold.lock"
exec 9>"$LOCK_FILE" || { echo "${RED}Could not open lockfile $LOCK_FILE${NC}"; exit 10; }
flock -n 9 || { echo -e "${YELLOW}Another instance is running. Exiting.${NC}"; exit 7; }

# Cleanup function for trapping signals
cleanup_remove() {
    cleanup "Old backups removal process" "Remove Old"
}
trap cleanup_remove INT TERM

log "INFO" "Starting removal of old archive/log files in $fullPath older than $BACKUP_RETAIN_DURATION days"
update_status "STARTED" "Removal of old backups in $fullPath"

# Build patterns for find command
archive_pattern=""
for ext in "${ARCHIVE_EXTS[@]}"; do
    archive_pattern="$archive_pattern -o -iname \"*.$ext\""
done
archive_pattern="${archive_pattern:4}"  # Remove initial " -o "

# Build find commands
FIND_ARCHIVES="find \"$fullPath\" -type f \( $(
    for ext in "${ARCHIVE_EXTS[@]}"; do
        echo -n "-iname '*.$ext' -o "
    done | sed 's/ -o $//'
) \) -mtime +$BACKUP_RETAIN_DURATION"

FIND_LOGS="find \"$fullPath\" -type f -iname '*.log' -mtime +$BACKUP_RETAIN_DURATION -size +${MAX_LOG_SIZE}c"

# Initialize counters
total_archives_deleted=0
total_logs_deleted=0
total_archives_size=0
total_logs_size=0
archives_to_remove=()
logs_to_remove=()

# Function to remove files and return count and size
remove_files() {
    local files=("$@")
    local counter=0
    local total_size=0
    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            size=$(stat -c %s "$f" 2>/dev/null)
            [ -z "$size" ] && size=0
            if [ "$DRY_RUN" = false ]; then
                echo -e "${RED}Removing: $f ($(numfmt --to=iec --suffix=B $size 2>/dev/null || echo ${size}B))${NC}"
                rm -f -- "$f"
            else
                echo -e "${YELLOW}Would remove: $f ($(numfmt --to=iec --suffix=B $size 2>/dev/null || echo ${size}B))${NC}"
            fi
            counter=$((counter+1))
            total_size=$((total_size+size))
        fi
    done
    echo "$counter $total_size"
}

# Find and collect old archive files
eval "$FIND_ARCHIVES" | while read -r f; do
    [ -n "$f" ] && archives_to_remove+=("$f")
done
if [ "${#archives_to_remove[@]}" -gt 0 ]; then
    log "INFO" "Found ${#archives_to_remove[@]} archive files to remove."
    read total_archives_deleted total_archives_size < <(remove_files "${archives_to_remove[@]}")
else
    log "INFO" "No archive files found for removal."
fi

# Find and collect old and large log files
eval "$FIND_LOGS" | while read -r f; do
    [ -n "$f" ] && logs_to_remove+=("$f")
done
if [ "${#logs_to_remove[@]}" -gt 0 ]; then
    log "INFO" "Found ${#logs_to_remove[@]} log files to remove."
    read total_logs_deleted total_logs_size < <(remove_files "${logs_to_remove[@]}")
else
    log "INFO" "No log files found for removal."
fi

# Create summary
SUMMARY_FILE=$(mktemp)
echo "Backup Cleanup Summary" > "$SUMMARY_FILE"
echo "======================" >> "$SUMMARY_FILE"
echo "Date: $(date)" >> "$SUMMARY_FILE"
echo "Host: $(hostname)" >> "$SUMMARY_FILE"
echo "Path: $fullPath" >> "$SUMMARY_FILE"
echo "Retention Period: $BACKUP_RETAIN_DURATION days" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Archives removed: $total_archives_deleted" >> "$SUMMARY_FILE"
echo "Archives size freed: $(numfmt --to=iec --suffix=B $total_archives_size 2>/dev/null || echo ${total_archives_size}B)" >> "$SUMMARY_FILE"
echo "Log files removed: $total_logs_deleted" >> "$SUMMARY_FILE"
echo "Log size freed: $(numfmt --to=iec --suffix=B $total_logs_size 2>/dev/null || echo ${total_logs_size}B)" >> "$SUMMARY_FILE"
echo "Total size freed: $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)" >> "$SUMMARY_FILE"

# Send notification
if [ "$DRY_RUN" = false ]; then
    if [ $total_archives_deleted -gt 0 ] || [ $total_logs_deleted -gt 0 ]; then
        notify "SUCCESS" "Removed $total_archives_deleted archives and $total_logs_deleted log files, freeing $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)" "Backup Cleanup" "$SUMMARY_FILE"
    else
        notify "INFO" "No files needed to be removed." "Backup Cleanup" "$SUMMARY_FILE"
    fi
else
    notify "INFO" "Dry run: Would have removed $total_archives_deleted archives and $total_logs_deleted log files" "Backup Cleanup" "$SUMMARY_FILE"
fi

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Removal process completed in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Removed $total_archives_deleted archives and $total_logs_deleted logs in ${FORMATTED_DURATION}"

# Display summary
echo -e "${GREEN}${BOLD}Backup Cleanup Summary:${NC}"
echo -e "${GREEN}Archives removed:${NC} $total_archives_deleted"
echo -e "${GREEN}Archives size freed:${NC} $(numfmt --to=iec --suffix=B $total_archives_size 2>/dev/null || echo ${total_archives_size}B)"
echo -e "${GREEN}Log files removed:${NC} $total_logs_deleted"
echo -e "${GREEN}Log size freed:${NC} $(numfmt --to=iec --suffix=B $total_logs_size 2>/dev/null || echo ${total_logs_size}B)"
echo -e "${GREEN}Total size freed:${NC} $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)"
echo -e "${GREEN}Time taken:${NC} ${FORMATTED_DURATION}"

# Clean up
rm -f "$SUMMARY_FILE"

exit 0
