#!/bin/bash

# ====== Professional WordPress Backup Old Files Remover ======
# Removes old backup files by time, disk space, or both criteria.
# All log and status messaging in English, using color output.

. "$(dirname "$0")/common.sh"

SAFE_PATHS=("/var/backups" "/home/backup" "$SCRIPTPATH/backups")
ARCHIVE_EXTS=("zip" "tar" "tar.gz" "tgz" "gz" "bz2" "xz" "7z")
LOG_FILE="$SCRIPTPATH/logs/remove_old.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/remove_old_status.log}"
MAX_LOG_SIZE=$((200*1024*1024))
DRY_RUN=false
VERBOSE=false

# --- New configuration fields
DISK_FREE_ENABLE="n"    # (y/n)
DISK_MIN_FREE_GB=0      # integer (GB)
CLEANUP_MODE="time"     # time | space | both
# ---

# Show usage/help
function usage() {
 echo -e "${GREEN}Usage: $0 -c <config_file> [-d] [-v] [--help]${NC}"
 echo -e "  -c <config_file>     Path to config file"
 echo -e "  -d                   Dry run (do not delete, just print)"
 echo -e "  -v                   Verbose output"
 echo -e "  --help               Show help"
 exit 0
}

# Parse flags (classic and GNU style)
while [[ "$#" -gt 0 ]]; do
 case "$1" in
  -c) CONFIG_FILE="$2"; shift 2 ;;
  -d) DRY_RUN=true; shift ;;
  -v) VERBOSE=true; shift ;;
  --help|-h) usage ;;
   *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
 esac
done

# Load configuration
if [ -z "$CONFIG_FILE" ]; then
 echo -e "${RED}Error: Config file not specified! Use -c <config_file>${NC}" >&2
 exit 1
elif [ ! -f "$CONFIG_FILE" ]; then
 echo -e "${RED}Error: Config file $CONFIG_FILE not found!${NC}" >&2
 exit 1
else
 . "$CONFIG_FILE"
fi

# Set defaults for new options if not present
DISK_FREE_ENABLE="${DISK_FREE_ENABLE:-n}"
DISK_MIN_FREE_GB="${DISK_MIN_FREE_GB:-0}"
CLEANUP_MODE="${CLEANUP_MODE:-time}"

for var in fullPath BACKUP_RETAIN_DURATION; do
 if [ -z "${!var}" ]; then
  echo -e "${RED}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
  exit 1
 fi
done

FOUND_SAFE=0
for dir in "${SAFE_PATHS[@]}"; do
 [[ "$fullPath" == $dir* ]] && FOUND_SAFE=1
done
if [ "$FOUND_SAFE" -ne 1 ]; then
 echo -e "${RED}Error: The path $fullPath is not in allowed (safe) paths.${NC}"
 exit 2
fi

NICE_LEVEL="${NICE_LEVEL:-19}"
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"

LOCK_FILE="/var/lock/removeold.lock"
exec 9>"$LOCK_FILE" || { echo "${RED}Could not open lockfile $LOCK_FILE${NC}"; exit 10; }
flock -n 9 || { echo -e "${YELLOW}Another instance is running. Exiting.${NC}"; exit 7; }

cleanup_remove() {
 cleanup "Old backups removal process" "Remove Old"
}
trap cleanup_remove INT TERM

# Helper function: Get free disk space (GB) at target path
get_disk_free_gb() {
 local gb
 gb=$(df -BG --output=avail "$fullPath" 2>/dev/null | tail -1 | tr -dc '0-9')
 echo "$gb"
}

log "INFO" "Starting removal of old archive/log files in $fullPath"
update_status "STARTED" "Removal of old backups in $fullPath"

archive_pattern=""
for ext in "${ARCHIVE_EXTS[@]}"; do
 archive_pattern="$archive_pattern -o -iname \"*.$ext\""
done
archive_pattern="${archive_pattern:4}" # Remove initial " -o "

# Find commands for old archives and log files
FIND_ARCHIVES="find \"$fullPath\" -type f $ $(
  for ext in "${ARCHIVE_EXTS[@]}"; do
   echo -n "-iname '*.$ext' -o "
  done | sed 's/ -o $//'
) $ -mtime +$BACKUP_RETAIN_DURATION"

FIND_LOGS="find \"$fullPath\" -type f -iname '*.log' -mtime +$BACKUP_RETAIN_DURATION -size +${MAX_LOG_SIZE}c"

total_archives_deleted=0
total_logs_deleted=0
total_archives_size=0
total_logs_size=0
archives_to_remove=()
logs_to_remove=()

# Decide whether to (physically) delete a file, depending on selected criteria
should_delete_file() {
 local file="$1"

 # "time": Remove files older than retention
 if [[ "$CLEANUP_MODE" == "time" ]]; then
  return 0
 # "space": Remove oldest files until enough disk free space
 elif [[ "$CLEANUP_MODE" == "space" ]]; then
  local free_gb=$(get_disk_free_gb)
  if (( free_gb < DISK_MIN_FREE_GB )); then
   return 0
  else
   return 1
  fi
 # "both": Remove files older than retention IF disk free space is below threshold
 elif [[ "$CLEANUP_MODE" == "both" ]]; then
  local min_age_days=$BACKUP_RETAIN_DURATION
  local file_age_days=$(( ( $(date +%s) - $(stat -c %Y "$file") ) / 86400 ))
  if (( file_age_days >= min_age_days )); then
   local free_gb=$(get_disk_free_gb)
   if (( free_gb < DISK_MIN_FREE_GB )); then
    return 0
   else
    return 1
   fi
  else
   return 1
  fi
 fi
 return 1
}

# Remove candidates function (for archives/logs)
remove_files() {
 local files=("$@")
 local counter=0
 local total_size=0

 # For space-based cleanup, sort files by modification time (oldest first)
 if [[ "$CLEANUP_MODE" == "space" ]]; then
  IFS=$'\n' files=( $(for f in "${files[@]}"; do [[ -f "$f" ]] && echo "$(stat -c "%Y $f")"; done | sort -n | awk '{print $2}' ) )
 fi

 for f in "${files[@]}"; do
  if [ -f "$f" ]; then
   if should_delete_file "$f"; then
    size=$(stat -c %s "$f" 2>/dev/null)
    [ -z "$size" ] && size=0
    if [ "$DRY_RUN" = false ]; then
     echo -e "${RED}Removing: $f ($(numfmt --to=iec --suffix=B $size 2>/dev/null || echo ${size}B))${NC}"
     rm -f -- "$f"
    else
     echo -e "${YELLOW}Would remove: $f ($(numfmt --to=iec --suffix=B $size 2>/dev/null || echo ${size}B))${NC}"
    fi
    ((counter++))
    ((total_size+=size))
    # For space or both, re-check disk space and possibly stop if enough free
    if [[ "$CLEANUP_MODE" =~ space|both ]]; then
     free_gb=$(get_disk_free_gb)
     if (( free_gb >= DISK_MIN_FREE_GB )); then
      break
     fi
    fi
   fi
  fi
 done
 echo "$counter $total_size"
}

# Disk free before cleanup
DISK_BEFORE=$(get_disk_free_gb)

# Build delete candidate list (archives)
eval "$FIND_ARCHIVES" | while read -r f; do
 [ -n "$f" ] && archives_to_remove+=("$f")
done
if [ "${#archives_to_remove[@]}" -gt 0 ]; then
 log "INFO" "Found ${#archives_to_remove[@]} archive files for deletion."
 read total_archives_deleted total_archives_size < <(remove_files "${archives_to_remove[@]}")
else
 log "INFO" "No archive files found for removal."
fi

eval "$FIND_LOGS" | while read -r f; do
 [ -n "$f" ] && logs_to_remove+=("$f")
done
if [ "${#logs_to_remove[@]}" -gt 0 ]; then
 log "INFO" "Found ${#logs_to_remove[@]} log files for deletion."
 read total_logs_deleted total_logs_size < <(remove_files "${logs_to_remove[@]}")
else
 log "INFO" "No log files found for removal."
fi

DISK_AFTER=$(get_disk_free_gb)

SUMMARY_FILE=$(mktemp)
echo "Backup Cleanup Summary" > "$SUMMARY_FILE"
echo "======================" >> "$SUMMARY_FILE"
echo "Date: $(date)" >> "$SUMMARY_FILE"
echo "Host: $(hostname)" >> "$SUMMARY_FILE"
echo "Target Path: $fullPath" >> "$SUMMARY_FILE"
echo "Retention Period: $BACKUP_RETAIN_DURATION days" >> "$SUMMARY_FILE"
echo "Cleanup Mode: $CLEANUP_MODE" >> "$SUMMARY_FILE"
echo "Disk free minimum (GB): $DISK_MIN_FREE_GB" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Archives removed: $total_archives_deleted" >> "$SUMMARY_FILE"
echo "Archives size freed: $(numfmt --to=iec --suffix=B $total_archives_size 2>/dev/null || echo ${total_archives_size}B)" >> "$SUMMARY_FILE"
echo "Logs removed: $total_logs_deleted" >> "$SUMMARY_FILE"
echo "Logs size freed: $(numfmt --to=iec --suffix=B $total_logs_size 2>/dev/null || echo ${total_logs_size}B)" >> "$SUMMARY_FILE"
echo "Total size freed: $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)" >> "$SUMMARY_FILE"
echo "Disk free before: ${DISK_BEFORE:-N/A} GB" >> "$SUMMARY_FILE"
echo "Disk free after:  ${DISK_AFTER:-N/A} GB" >> "$SUMMARY_FILE"

if [ "$DRY_RUN" = false ]; then
 if [ $total_archives_deleted -gt 0 ] || [ $total_logs_deleted -gt 0 ]; then
  notify "SUCCESS" "Removed $total_archives_deleted archives and $total_logs_deleted logs, freed $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)" "Backup Cleanup" "$SUMMARY_FILE"
 else
  notify "INFO" "No files needed to be removed." "Backup Cleanup" "$SUMMARY_FILE"
 fi
else
 notify "INFO" "Dry run: Would have removed $total_archives_deleted archives and $total_logs_deleted logs" "Backup Cleanup" "$SUMMARY_FILE"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Removal process completed in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Removed $total_archives_deleted archives and $total_logs_deleted logs in ${FORMATTED_DURATION}"

echo -e "${GREEN}${BOLD}Backup Cleanup Summary:${NC}"
echo -e "${GREEN}Archives removed:${NC} $total_archives_deleted"
echo -e "${GREEN}Archives size freed:${NC} $(numfmt --to=iec --suffix=B $total_archives_size 2>/dev/null || echo ${total_archives_size}B)"
echo -e "${GREEN}Logs removed:${NC} $total_logs_deleted"
echo -e "${GREEN}Logs size freed:${NC} $(numfmt --to=iec --suffix=B $total_logs_size 2>/dev/null || echo ${total_logs_size}B)"
echo -e "${GREEN}Total size freed:${NC} $(numfmt --to=iec --suffix=B $((total_archives_size + total_logs_size)) 2>/dev/null || echo $((total_archives_size + total_logs_size))B)"
echo -e "${GREEN}Disk free before:${NC} ${DISK_BEFORE:-N/A} GB"
echo -e "${GREEN}Disk free after:${NC}  ${DISK_AFTER:-N/A} GB"
echo -e "${GREEN}Time taken:${NC} ${FORMATTED_DURATION}"

rm -f "$SUMMARY_FILE"
exit 0