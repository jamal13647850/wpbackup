#!/bin/bash
#
# Script: update_scripts.sh
# Author: Sayyed Jamal Ghasemi (Further modified by Bash Script Developer AI)
# Date: 2025-05-27
#
# Description: Updates the script suite from a GitHub repository.
#              If the target directory is not a Git repository, it will be
#              populated by cloning the repository. Existing files will be overwritten.
#              Locally important directories like 'logs/', 'configs/', 'local_backups/',
#              and 'backups/' will be preserved.
#              If it is a Git repository, it will be hard reset to the
#              specified remote branch, overwriting local changes.

# Source common functions and variables
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

# --- Script specific log files ---
LOG_FILE="$SCRIPTPATH/logs/update_scripts.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/update_scripts_status.log}"

# --- Configuration - Based on User Feedback ---
DEFAULT_GIT_REPO_URL="https://github.com/jamal13647850/wpbackup"
DEFAULT_GIT_BRANCH="main"
DEFAULT_TARGET_DIR="$SCRIPTPATH" 

# --- Default values for options ---
VERBOSE=false
QUIET=false

# Function to display help message
display_help() {
    echo -e "${GREEN}${BOLD}Usage:${NC} $0 [-t <target_dir>] [-r <repo_url>] [-b <branch>] [-q] [-v] [-h]"
    echo -e "Description: Updates scripts from Git. Overwrites local changes/files by default."
    echo -e "           Default target: '$DEFAULT_TARGET_DIR'"
    echo -e "           Default repository: '$DEFAULT_GIT_REPO_URL'"
    echo -e "           Default branch: '$DEFAULT_GIT_BRANCH'"
    echo -e "\nOptions:"
    echo -e "  -t <target_dir>  Override the target directory (default: '$DEFAULT_TARGET_DIR')."
    echo -e "  -r <repo_url>    Override the Git repository URL (default: '$DEFAULT_GIT_REPO_URL')."
    echo -e "  -b <branch>      Override the Git branch (default: '$DEFAULT_GIT_BRANCH')."
    echo -e "  -q               Quiet mode (minimal output)."
    echo -e "  -v               Enable verbose logging."
    echo -e "  -h               Display this help message."
    exit 0
}

# --- Effective Configuration (Allowing overrides from cmd line) ---
EFFECTIVE_TARGET_DIR="$DEFAULT_TARGET_DIR"
EFFECTIVE_REPO_URL="$DEFAULT_GIT_REPO_URL"
EFFECTIVE_BRANCH="$DEFAULT_GIT_BRANCH"

# Parse command line options
while getopts "t:r:b:qvh" opt; do
    case $opt in
        t) EFFECTIVE_TARGET_DIR="$OPTARG";;
        r) EFFECTIVE_REPO_URL="$OPTARG";;
        b) EFFECTIVE_BRANCH="$OPTARG";;
        q) QUIET=true;;
        v) VERBOSE=true;;
        h) display_help;;
        \?) echo -e "${RED}${BOLD}Error: Invalid option '$OPTARG'.${NC}" >&2; display_help;;
    esac
done

init_log "Scripts Updater"

if [ "$QUIET" = true ]; then export LOG_LEVEL="quiet"; fi
if [ "$VERBOSE" = true ]; then export LOG_LEVEL="verbose"; fi

if ! command_exists git; then
    log "ERROR" "Git command ('git') not found. Please install Git."
    update_status "FAILURE" "Git command not found"
    [ "${NOTIFY:-true}" == true ] && notify "FAILURE" "Git command ('git') not found. Scripts Updater cannot run." "Scripts Updater"
    exit 1
fi

TARGET_DIR_ABS=""
if [ ! -d "$EFFECTIVE_TARGET_DIR" ]; then
    log "INFO" "Target directory '$EFFECTIVE_TARGET_DIR' does not exist. Attempting to create it."
    if ! mkdir -p "$EFFECTIVE_TARGET_DIR"; then
        log "ERROR" "Failed to create target directory '$EFFECTIVE_TARGET_DIR'."
        update_status "FAILURE" "Cannot create target directory $EFFECTIVE_TARGET_DIR"
        [ "${NOTIFY:-true}" == true ] && notify "FAILURE" "Failed to create target directory '$EFFECTIVE_TARGET_DIR'." "Scripts Updater"
        exit 1
    fi
fi

TARGET_DIR_ABS="$(cd "$EFFECTIVE_TARGET_DIR" && pwd)"
if [ -z "$TARGET_DIR_ABS" ]; then
    log "ERROR" "Failed to resolve absolute path for target directory '$EFFECTIVE_TARGET_DIR'."
    update_status "FAILURE" "Cannot resolve path for $EFFECTIVE_TARGET_DIR"
    exit 1
fi
log "INFO" "Effective target directory for update: $TARGET_DIR_ABS"
log "INFO" "Effective repository: $EFFECTIVE_REPO_URL"
log "INFO" "Effective branch: $EFFECTIVE_BRANCH"
log "INFO" "Update policy: Overwrite local changes/files from repository, preserving specified local directories."

if ! $QUIET; then
    echo -e "${CYAN}Updating scripts in '$TARGET_DIR_ABS'${NC}"
    echo -e "${INFO}From Repository: ${BOLD}$EFFECTIVE_REPO_URL${NC}"
    echo -e "${INFO}Branch: ${BOLD}$EFFECTIVE_BRANCH${NC}"
    echo -e "${INFO}Policy: ${BOLD}Local changes/files will be overwritten by repository version.${NC}"
    echo -e "${INFO}        ${BOLD}Local 'logs/', 'configs/', 'local_backups/', 'backups/' directories will be preserved.${NC}"
fi
update_status "STARTED" "Updating from $EFFECTIVE_REPO_URL branch $EFFECTIVE_BRANCH to $TARGET_DIR_ABS"

if [ -d "$TARGET_DIR_ABS/.git" ]; then
    log "INFO" "Target directory '$TARGET_DIR_ABS' is a Git repository. Proceeding with overwrite."
    if ! $QUIET; then echo -e "${CYAN}Updating existing Git repository (forcing overwrite)...${NC}"; fi

    cd "$TARGET_DIR_ABS" || {
        log "ERROR" "Could not change directory to '$TARGET_DIR_ABS'."
        update_status "FAILURE" "Cannot cd to $TARGET_DIR_ABS"
        exit 1 
    }

    current_origin_url=$(git config --get remote.origin.url)
    if [ "$current_origin_url" != "$EFFECTIVE_REPO_URL" ]; then
        log "INFO" "Updating remote 'origin' URL from '$current_origin_url' to '$EFFECTIVE_REPO_URL'."
        git remote set-url origin "$EFFECTIVE_REPO_URL"
        check_status $? "Updating remote 'origin' URL" "Scripts Updater"
    fi
    
    log "INFO" "Fetching changes from remote 'origin'."
    git fetch origin --prune
    check_status $? "Git fetch origin --prune" "Scripts Updater"
    
    log "INFO" "Attempting to switch to branch '$EFFECTIVE_BRANCH'."
    git checkout "$EFFECTIVE_BRANCH" 2>/dev/null
    # If checkout failed or was already on branch, reset --hard will align it with origin's version.
    
    log "INFO" "Resetting local branch '$EFFECTIVE_BRANCH' to match 'origin/$EFFECTIVE_BRANCH' (discards local changes to tracked files)."
    git reset --hard "origin/$EFFECTIVE_BRANCH"
    check_status $? "Git reset --hard origin/$EFFECTIVE_BRANCH" "Scripts Updater"
    
    log "INFO" "Cleaning untracked files and directories, excluding important local directories."
    git clean -fdx \
        -e logs/ \
        -e configs/ \
        -e local_backups/ \
        -e backups/
        # Add other exclusions if needed, e.g. -e '.idea/'
    check_status $? "Git clean -fdx (with exclusions)" "Scripts Updater"

    log "INFO" "Local branch '$EFFECTIVE_BRANCH' is now aligned with 'origin/$EFFECTIVE_BRANCH' and working directory is updated, preserving important local directories."

else
    log "INFO" "Target directory '$TARGET_DIR_ABS' is not a Git repository. Full overwrite from clone, preserving specified local directories."
    if ! $QUIET; then echo -e "${CYAN}Target is not a Git repo. Performing full overwrite (specified local directories preserved)...${NC}"; fi

    PRESERVE_ITEMS=("logs" "configs" "local_backups" "backups") 
    PRESERVED_DATA_BACKUP_PATH=""
    PRESERVED_DATA_BACKUP_PATH=$(mktemp -d "$SCRIPTPATH/wpb_preserve_XXXXXX")

    if [ -z "$PRESERVED_DATA_BACKUP_PATH" ] || [ ! -d "$PRESERVED_DATA_BACKUP_PATH" ]; then
        log "ERROR" "Failed to create temporary directory for preserving data. Path: '$SCRIPTPATH/wpb_preserve_XXXXXX'"
        update_status "FAILURE" "Failed to create data preservation backup directory"
        exit 1
    fi
    log "DEBUG" "Preservation backup directory created: $PRESERVED_DATA_BACKUP_PATH"

    for item_to_preserve in "${PRESERVE_ITEMS[@]}"; do
        if [ -e "$TARGET_DIR_ABS/$item_to_preserve" ]; then
            log "INFO" "Backing up '$TARGET_DIR_ABS/$item_to_preserve' to '$PRESERVED_DATA_BACKUP_PATH/'"
            # Create the specific subdirectory in the backup path before copying
            mkdir -p "$PRESERVED_DATA_BACKUP_PATH/$item_to_preserve" && \
            # Copy contents of the item. Using `/.` ensures that if item_to_preserve is a directory, its contents are copied.
            cp -a "$TARGET_DIR_ABS/$item_to_preserve/." "$PRESERVED_DATA_BACKUP_PATH/$item_to_preserve/" &>/dev/null
            if [ $? -ne 0 ]; then
                log "WARNING" "Failed to fully back up '$TARGET_DIR_ABS/$item_to_preserve'. Some preserved files might be lost."
            fi
        else
             log "DEBUG" "Item '$TARGET_DIR_ABS/$item_to_preserve' not found for backup. Skipping."
        fi
    done

    NEW_CLONE_PATH="$TARGET_DIR_ABS.new_clone_$(date +%Y%m%d%H%M%S)"
    log "INFO" "Cloning '$EFFECTIVE_REPO_URL' (branch '$EFFECTIVE_BRANCH') into '$NEW_CLONE_PATH'."

    git clone --depth 1 --branch "$EFFECTIVE_BRANCH" "$EFFECTIVE_REPO_URL" "$NEW_CLONE_PATH"
    CLONE_STATUS=$?

    if [ $CLONE_STATUS -eq 0 ]; then
        log "INFO" "Clone successful. Syncing files to '$TARGET_DIR_ABS'."
        if ! $QUIET; then echo -e "${CYAN}Syncing cloned files to target directory...${NC}"; fi
        
        # Rsync all content from the new clone to the target directory.
        # --delete ensures that files in TARGET_DIR_ABS not present in NEW_CLONE_PATH are removed.
        # Exclude .gitkeep or other placeholder files if they exist in the repo and are not meant for the final dir.
        rsync -a --delete --exclude='.gitkeep' "$NEW_CLONE_PATH/" "$TARGET_DIR_ABS/" 
        RSYNC_STATUS=$?
        
        if [ $RSYNC_STATUS -eq 0 ]; then
            log "INFO" "Initial rsync successful. Restoring preserved items."
            # Restore preserved items. This will overwrite any files from the repo
            # that might have the same names as preserved items (e.g., a default config in repo).
            for item_to_preserve in "${PRESERVE_ITEMS[@]}"; do
                if [ -d "$PRESERVED_DATA_BACKUP_PATH/$item_to_preserve" ]; then # Check if backup was made and is a directory
                    log "INFO" "Restoring '$item_to_preserve' from backup to '$TARGET_DIR_ABS/'."
                    # Ensure target sub-directory exists before copying contents
                    mkdir -p "$TARGET_DIR_ABS/$item_to_preserve" && \
                    # Use rsync for restore as well, it's robust. Source path needs `/.`
                    rsync -a "$PRESERVED_DATA_BACKUP_PATH/$item_to_preserve/." "$TARGET_DIR_ABS/$item_to_preserve/"
                    if [ $? -ne 0 ]; then
                        log "WARNING" "Failed to fully restore '$item_to_preserve'. Check '$TARGET_DIR_ABS/$item_to_preserve'."
                    fi
                fi
            done
            log "INFO" "Directory '$TARGET_DIR_ABS' updated from clone. It is now a Git repository."
        else
            log "ERROR" "Rsync failed with status $RSYNC_STATUS while syncing from '$NEW_CLONE_PATH'."
            update_status "FAILURE" "Rsync failed during update from clone"
        fi
    else
        log "ERROR" "Git clone failed with status $CLONE_STATUS from '$EFFECTIVE_REPO_URL'."
        update_status "FAILURE" "Git clone failed"
    fi

    # Clean up temporary clone and backup directories
    if [ -d "$NEW_CLONE_PATH" ]; then rm -rf "$NEW_CLONE_PATH"; fi
    if [ -d "$PRESERVED_DATA_BACKUP_PATH" ]; then rm -rf "$PRESERVED_DATA_BACKUP_PATH"; fi
    
    # If clone or rsync failed, the update is considered failed.
    if [ $CLONE_STATUS -ne 0 ] || { [ $CLONE_STATUS -eq 0 ] && [ "${RSYNC_STATUS:-1}" -ne 0 ]; }; then
        log "ERROR" "Update process failed due to clone or rsync errors."
        [ "${NOTIFY:-true}" == true ] && notify "FAILURE" "Update of scripts in '$TARGET_DIR_ABS' failed (clone/rsync error)." "Scripts Updater"
        exit 1
    fi
fi

# --- Finalization ---
CURRENT_COMMIT_HASH=""
if [ -d "$TARGET_DIR_ABS/.git" ]; then
    CURRENT_COMMIT_HASH=$(cd "$TARGET_DIR_ABS" && git rev-parse --short HEAD 2>/dev/null || echo "N/A")
else
    # This case should ideally not be reached if clone was successful, as .git would then exist.
    CURRENT_COMMIT_HASH="N/A (clone may have failed or dir not a git repo post-operation)"
fi

log "INFO" "Successfully updated scripts in '$TARGET_DIR_ABS' to branch '$EFFECTIVE_BRANCH' (Commit: $CURRENT_COMMIT_HASH)."
update_status "SUCCESS" "Scripts updated to $EFFECTIVE_BRANCH (Commit: $CURRENT_COMMIT_HASH)"

if ! $QUIET; then
    echo -e "${GREEN}${BOLD}Scripts updated successfully to branch '$EFFECTIVE_BRANCH'!${NC}"
    if [[ "$CURRENT_COMMIT_HASH" != "N/A"* ]]; then # Check if not starting with "N/A"
        echo -e "${GREEN}Current version:${NC}"
        (cd "$TARGET_DIR_ABS" && git log -1 --pretty=format:"  %h - %s (%an, %ar)")
    fi
fi
[ "${NOTIFY:-true}" == true ] && notify "SUCCESS" "Scripts in '$TARGET_DIR_ABS' updated to branch '$EFFECTIVE_BRANCH' (Commit: $CURRENT_COMMIT_HASH)." "Scripts Updater"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Script update process completed in ${FORMATTED_DURATION}."
if ! $QUIET; then echo -e "${CYAN}Update process finished in ${FORMATTED_DURATION}.${NC}"; fi

exit 0