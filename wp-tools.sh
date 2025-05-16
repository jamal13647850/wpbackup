#!/bin/bash
# wp-tools.sh - WordPress management and maintenance tools
# Author: System Administrator
# Last updated: 2025-05-16

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files for this script
LOG_FILE="$SCRIPTPATH/wp-tools.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/wp-tools_status.log}"

# Initialize default values
DRY_RUN=false
VERBOSE=false
WP_OPERATION=""
WP_ARGS=""

# Parse command line options
while getopts "c:o:a:dv" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        o) WP_OPERATION="$OPTARG";;
        a) WP_ARGS="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> -o <operation> [-a <wp-cli arguments>] [-d] [-v]" >&2
            echo -e "  -c: Configuration file"
            echo -e "  -o: WordPress operation (update, optimize, check, clean, info)"
            echo -e "  -a: Additional WP-CLI arguments (in quotes)"
            echo -e "  -d: Dry run (no actual changes)"
            echo -e "  -v: Verbose output"
            echo
            echo -e "${CYAN}Available operations:${NC}"
            echo -e "  update    - Update WordPress core, plugins, and themes"
            echo -e "  optimize  - Optimize database tables and regenerate thumbnails"
            echo -e "  check     - Check WordPress installation for issues"
            echo -e "  clean     - Clean up transients, revisions, and trash"
            echo -e "  info      - Display WordPress information"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Tools"

# If no config file specified, prompt user to select one
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "wp-tools"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$CONFIG_FILE")${NC}"
fi

# Source the config file
. <(load_config "$CONFIG_FILE")

# Validate required configuration variables for WordPress path
if [ -z "$wpPath" ]; then
    echo -e "${RED}${BOLD}Error: Required variable wpPath is not set in $CONFIG_FILE!${NC}" >&2
    exit 1
fi

# Set default options
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
NICE_LEVEL="${NICE_LEVEL:-19}"

# Check if WP-CLI is installed
if ! command_exists wp; then
    echo -e "${RED}${BOLD}Error: WP-CLI is not installed. Please install it first.${NC}" >&2
    exit 1
fi

# Check if operation is specified
if [ -z "$WP_OPERATION" ]; then
    echo -e "${RED}${BOLD}Error: No operation specified. Use -o option.${NC}" >&2
    exit 1
fi

# Function for cleanup operations
cleanup_wp_tools() {
    cleanup "WordPress tools process" "WordPress tools"
}

trap cleanup_wp_tools INT TERM

# Start WordPress tools process
log "INFO" "Starting WordPress tools process for $WP_OPERATION"
update_status "STARTED" "WordPress tools process for $WP_OPERATION"

# Check if WordPress directory exists
if [ ! -d "$wpPath" ]; then
    log "ERROR" "WordPress directory $wpPath does not exist"
    echo -e "${RED}${BOLD}Error: WordPress directory $wpPath does not exist!${NC}" >&2
    exit 1
fi

# Check if directory is a WordPress installation
if [ ! -f "$wpPath/wp-config.php" ]; then
    log "ERROR" "Not a WordPress installation at $wpPath"
    echo -e "${RED}${BOLD}Error: Not a WordPress installation at $wpPath!${NC}" >&2
    exit 1
fi

# Function to run WP-CLI command
run_wp_cli() {
    local command="$1"
    local description="$2"
    local args="$3"
    
    echo -e "${CYAN}${BOLD}$description...${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would execute: wp $command $args${NC}"
        return 0
    else
        log "DEBUG" "Executing: wp $command $args"
        nice -n "$NICE_LEVEL" wp "$command" $args --path="$wpPath"
        return $?
    fi
}

# Execute WordPress operation
case "$WP_OPERATION" in
    update)
        log "INFO" "Performing WordPress update operation"
        echo -e "${GREEN}${BOLD}=== WordPress Update ===${NC}"
        
        # Check for updates first
        run_wp_cli "core check-update" "Checking for WordPress core updates" "--format=table"
        run_wp_cli "plugin list" "Listing plugins" "--update=available --format=table"
        run_wp_cli "theme list" "Listing themes" "--update=available --format=table"
        
        # Perform updates
        if [ "$DRY_RUN" = false ]; then
            echo -e "${CYAN}${BOLD}Creating database backup before updates...${NC}"
            "$SCRIPTPATH/database.sh" -c "$CONFIG_FILE" -l
            check_status $? "Create database backup before updates" "WordPress tools"
        fi
        
        run_wp_cli "core update" "Updating WordPress core" "$WP_ARGS"
        check_status $? "Update WordPress core" "WordPress tools"
        
        run_wp_cli "plugin update --all" "Updating all plugins" "$WP_ARGS"
        check_status $? "Update plugins" "WordPress tools"
        
        run_wp_cli "theme update --all" "Updating all themes" "$WP_ARGS"
        check_status $? "Update themes" "WordPress tools"
        
        run_wp_cli "core update-db" "Updating WordPress database" "$WP_ARGS"
        check_status $? "Update WordPress database" "WordPress tools"
        ;;
        
    optimize)
        log "INFO" "Performing WordPress optimization operation"
        echo -e "${GREEN}${BOLD}=== WordPress Optimization ===${NC}"
        
        # Optimize database
        run_wp_cli "db optimize" "Optimizing database" "$WP_ARGS"
        check_status $? "Optimize database" "WordPress tools"
        
        # Regenerate thumbnails if media-regenerate command exists
        if wp help media regenerate --path="$wpPath" >/dev/null 2>&1; then
            run_wp_cli "media regenerate" "Regenerating thumbnails" "--yes $WP_ARGS"
            check_status $? "Regenerate thumbnails" "WordPress tools"
        else
            echo -e "${YELLOW}Skipping thumbnail regeneration: Command not available${NC}"
            log "INFO" "Skipping thumbnail regeneration: Command not available"
        fi
        
        # Rewrite flush
        run_wp_cli "rewrite flush" "Flushing rewrite rules" "$WP_ARGS"
        check_status $? "Flush rewrite rules" "WordPress tools"
        
        # Cache flush if available
        if wp help cache flush --path="$wpPath" >/dev/null 2>&1; then
            run_wp_cli "cache flush" "Flushing cache" "$WP_ARGS"
            check_status $? "Flush cache" "WordPress tools"
        else
            echo -e "${YELLOW}Skipping cache flush: Command not available${NC}"
            log "INFO" "Skipping cache flush: Command not available"
        fi
        ;;
        
    check)
        log "INFO" "Performing WordPress check operation"
        echo -e "${GREEN}${BOLD}=== WordPress Check ===${NC}"
        
        # Check WordPress core
        run_wp_cli "core verify-checksums" "Verifying WordPress core checksums" "$WP_ARGS"
        
        # Check plugins
        run_wp_cli "plugin verify-checksums --all" "Verifying plugin checksums" "$WP_ARGS"
        
        # Check database
        run_wp_cli "db check" "Checking database tables" "$WP_ARGS"
        
        # Security check
        run_wp_cli "core version" "Checking WordPress version" "--extra"
        
        # Check file permissions
        echo -e "${CYAN}${BOLD}Checking file permissions...${NC}"
        find "$wpPath" -type f -name "*.php" -exec ls -l {} \; | grep -v "^-rw-r--r--"
        
        # Check for debug logs
        echo -e "${CYAN}${BOLD}Checking for debug logs...${NC}"
        find "$wpPath" -name "debug.log" -type f
        ;;
        
    clean)
        log "INFO" "Performing WordPress cleanup operation"
        echo -e "${GREEN}${BOLD}=== WordPress Cleanup ===${NC}"
        
        # Delete transients
        run_wp_cli "transient delete --all" "Deleting all transients" "$WP_ARGS"
        check_status $? "Delete transients" "WordPress tools"
        
        # Delete expired transients
        run_wp_cli "transient delete-expired" "Deleting expired transients" "$WP_ARGS"
        check_status $? "Delete expired transients" "WordPress tools"
        
        # Delete post revisions
        run_wp_cli "post delete" "Deleting post revisions" "--force $(wp post list --post_type=revision --format=ids --path="$wpPath") $WP_ARGS"
        check_status $? "Delete post revisions" "WordPress tools"
        
        # Delete trashed posts
        run_wp_cli "post delete" "Deleting trashed posts" "--force --trash $(wp post list --post_status=trash --format=ids --path="$wpPath") $WP_ARGS"
        check_status $? "Delete trashed posts" "WordPress tools"
        
        # Delete spam comments
        run_wp_cli "comment delete" "Deleting spam comments" "--force $(wp comment list --status=spam --format=ids --path="$wpPath") $WP_ARGS"
        check_status $? "Delete spam comments" "WordPress tools"
        
        # Delete trashed comments
        run_wp_cli "comment delete" "Deleting trashed comments" "--force $(wp comment list --status=trash --format=ids --path="$wpPath") $WP_ARGS"
        check_status $? "Delete trashed comments" "WordPress tools"
        
        # Optimize database after cleanup
        run_wp_cli "db optimize" "Optimizing database after cleanup" "$WP_ARGS"
        check_status $? "Optimize database after cleanup" "WordPress tools"
        ;;
        
    info)
        log "INFO" "Displaying WordPress information"
        echo -e "${GREEN}${BOLD}=== WordPress Information ===${NC}"
        
        # WordPress core info
        run_wp_cli "core version" "WordPress version" "--extra"
        
        # WordPress site info
        run_wp_cli "option get siteurl" "Site URL" ""
        run_wp_cli "option get home" "Home URL" ""
        
        # Plugin info
        run_wp_cli "plugin list" "Installed plugins" "--format=table"
        
        # Theme info
        run_wp_cli "theme list" "Installed themes" "--format=table"
        
        # User info
        run_wp_cli "user list" "User list" "--format=table"
        
        # Database info
        run_wp_cli "db size" "Database size" "--format=table"
        
        # PHP info
        echo -e "${CYAN}${BOLD}PHP version:${NC}"
        php -v | head -n 1
        
        # Server info
        echo -e "${CYAN}${BOLD}Server information:${NC}"
        uname -a
        ;;
        
    *)
        log "ERROR" "Unknown operation: $WP_OPERATION"
        echo -e "${RED}${BOLD}Error: Unknown operation: $WP_OPERATION${NC}" >&2
        echo -e "${YELLOW}Available operations: update, optimize, check, clean, info${NC}"
        exit 1
        ;;
esac

# Calculate execution time and report success
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "WordPress tools process for $WP_OPERATION successfully completed in ${FORMATTED_DURATION}"
update_status "SUCCESS" "WordPress tools process for $WP_OPERATION completed in ${FORMATTED_DURATION}"
notify "SUCCESS" "WordPress tools process for $WP_OPERATION successfully completed in ${FORMATTED_DURATION}" "WordPress tools"

echo -e "${GREEN}${BOLD}WordPress tools operation completed successfully!${NC}"
echo -e "${GREEN}Operation: ${NC}${WP_OPERATION}"
echo -e "${GREEN}Time taken: ${NC}${FORMATTED_DURATION}"
