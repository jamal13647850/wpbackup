#!/bin/bash
# monitor.sh - WordPress monitoring script
# This script monitors WordPress installations and server health

. "$(dirname "$0")/common.sh"

# Set log files
LOG_FILE="$SCRIPTPATH/monitor.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/monitor_status.log}"

# Default values
VERBOSE=false
ALERT_ONLY=false
QUIET=false
REPORT_FILE="$SCRIPTPATH/monitor_report.txt"
METRICS_FILE="$SCRIPTPATH/monitor_metrics.csv"
THRESHOLD_FILE=""
DRY_RUN=false

# Parse command line options
while getopts "c:t:r:m:aqvd" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        t) THRESHOLD_FILE="$OPTARG";;
        r) REPORT_FILE="$OPTARG";;
        m) METRICS_FILE="$OPTARG";;
        a) ALERT_ONLY=true;;
        q) QUIET=true;;
        v) VERBOSE=true;;
        d) DRY_RUN=true;;
        ?)
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-t <threshold_file>] [-r <report_file>] [-m <metrics_file>] [-a] [-q] [-v] [-d]" >&2
            echo -e "  -c: Configuration file (can be encrypted .conf.gpg or regular .conf)"
            echo -e "  -t: Threshold configuration file"
            echo -e "  -r: Output report file (default: monitor_report.txt)"
            echo -e "  -m: Metrics CSV file (default: monitor_metrics.csv)"
            echo -e "  -a: Alert only mode (only report issues)"
            echo -e "  -q: Quiet mode (minimal output)"
            echo -e "  -v: Verbose output"
            echo -e "  -d: Dry run (no actual monitoring)"
            exit 1
            ;;
    esac
done

# Initialize log
init_log "WordPress Monitor"

# Select or load config file
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "monitor"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
fi

# Process config file
process_config_file "$CONFIG_FILE" "Monitor"

# Load threshold configuration if specified
if [ -n "$THRESHOLD_FILE" ]; then
    if [ -f "$THRESHOLD_FILE" ]; then
        . "$THRESHOLD_FILE"
        log "INFO" "Loaded threshold configuration from $THRESHOLD_FILE"
    else
        echo -e "${RED}${BOLD}Error: Threshold file $THRESHOLD_FILE not found!${NC}" >&2
        exit 1
    fi
fi

# Set log level based on verbosity
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
NICE_LEVEL="${NICE_LEVEL:-19}"

# Set default thresholds if not specified in config
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"
LOAD_THRESHOLD="${LOAD_THRESHOLD:-2}"
CONNECTIONS_THRESHOLD="${CONNECTIONS_THRESHOLD:-100}"
RESPONSE_TIME_THRESHOLD="${RESPONSE_TIME_THRESHOLD:-2}"
UPTIME_THRESHOLD="${UPTIME_THRESHOLD:-95}"
ERROR_LOG_THRESHOLD="${ERROR_LOG_THRESHOLD:-10}"
PLUGIN_UPDATE_THRESHOLD="${PLUGIN_UPDATE_THRESHOLD:-5}"
THEME_UPDATE_THRESHOLD="${THEME_UPDATE_THRESHOLD:-2}"
CORE_UPDATE_THRESHOLD="${CORE_UPDATE_THRESHOLD:-1}"

# Check required variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Check if WordPress exists
if [ ! -f "$wpPath/wp-config.php" ]; then
    echo -e "${RED}${BOLD}Error: WordPress not found at $wpPath!${NC}" >&2
    exit 1
fi

# Check if WP-CLI is installed
if ! command_exists wp; then
    echo -e "${RED}${BOLD}Error: WP-CLI is not installed!${NC}" >&2
    echo -e "${YELLOW}Please install WP-CLI and try again: https://wp-cli.org/#installing${NC}" >&2
    exit 1
fi

# Cleanup function for trapping signals
cleanup_monitor() {
    cleanup "Monitor process" "Monitor"
}
trap cleanup_monitor INT TERM

# Start monitoring process
log "INFO" "Starting WordPress monitoring process"
update_status "STARTED" "WordPress monitoring process"

# Initialize report and metrics files
if [ "$DRY_RUN" = false ]; then
    echo "WordPress Monitoring Report - $(date)" > "$REPORT_FILE"
    echo "=======================================" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Create metrics CSV header if it doesn't exist
    if [ ! -f "$METRICS_FILE" ]; then
        echo "timestamp,disk_usage,cpu_usage,memory_usage,load_avg,connections,response_time,uptime,error_count,plugin_updates,theme_updates,core_updates" > "$METRICS_FILE"
    fi
else
    log "INFO" "Dry run: Skipping report file initialization"
fi

# Function to check disk usage
check_disk_usage() {
    local path="$1"
    local threshold="$2"
    local usage

    usage=$(df -h "$path" | awk 'NR==2 {print $5}' | sed 's/%//')

    if [ "$DRY_RUN" = false ]; then
        echo "Disk Usage: ${usage}% (Threshold: ${threshold}%)" >> "$REPORT_FILE"

        if [ "$usage" -ge "$threshold" ]; then
            echo "  [WARNING] Disk usage is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Disk usage is above threshold: ${usage}% >= ${threshold}%"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Disk usage is above threshold: ${usage}% >= ${threshold}%"
            fi

            return 1
        else
            log "INFO" "Disk usage is normal: ${usage}% < ${threshold}%"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}Disk usage is normal:${NC} ${usage}% < ${threshold}%"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check disk usage"
        return 0
    fi
}

# Function to check CPU usage
check_cpu_usage() {
    local threshold="$1"
    local usage

    if command_exists mpstat; then
        usage=$(mpstat 1 1 | awk '$12 ~ /[0-9.]+/ {print 100 - $12}' | tail -n 1)
    else
        usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    fi

    usage=${usage%.*}

    if [ "$DRY_RUN" = false ]; then
        echo "CPU Usage: ${usage}% (Threshold: ${threshold}%)" >> "$REPORT_FILE"

        if [ "$usage" -ge "$threshold" ]; then
            echo "  [WARNING] CPU usage is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "CPU usage is above threshold: ${usage}% >= ${threshold}%"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} CPU usage is above threshold: ${usage}% >= ${threshold}%"
            fi

            return 1
        else
            log "INFO" "CPU usage is normal: ${usage}% < ${threshold}%"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}CPU usage is normal:${NC} ${usage}% < ${threshold}%"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check CPU usage"
        return 0
    fi
}

# Function to check memory usage
check_memory_usage() {
    local threshold="$1"
    local usage

    usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')

    if [ "$DRY_RUN" = false ]; then
        echo "Memory Usage: ${usage}% (Threshold: ${threshold}%)" >> "$REPORT_FILE"

        if [ "$usage" -ge "$threshold" ]; then
            echo "  [WARNING] Memory usage is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Memory usage is above threshold: ${usage}% >= ${threshold}%"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Memory usage is above threshold: ${usage}% >= ${threshold}%"
            fi

            return 1
        else
            log "INFO" "Memory usage is normal: ${usage}% < ${threshold}%"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}Memory usage is normal:${NC} ${usage}% < ${threshold}%"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check memory usage"
        return 0
    fi
}

# Function to check load average
check_load_average() {
    local threshold="$1"
    local load

    load=$(uptime | awk -F'[a-z]:' '{ print $2}' | awk -F',' '{print $1}' | tr -d ' ')

    if [ "$DRY_RUN" = false ]; then
        echo "Load Average (1 min): ${load} (Threshold: ${threshold})" >> "$REPORT_FILE"

        if (( $(echo "$load > $threshold" | bc -l) )); then
            echo "  [WARNING] Load average is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Load average is above threshold: ${load} >= ${threshold}"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Load average is above threshold: ${load} >= ${threshold}"
            fi

            return 1
        else
            log "INFO" "Load average is normal: ${load} < ${threshold}"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}Load average is normal:${NC} ${load} < ${threshold}"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check load average"
        return 0
    fi
}

# Function to check active connections
check_connections() {
    local threshold="$1"
    local connections

    connections=$(netstat -an | grep ESTABLISHED | wc -l)

    if [ "$DRY_RUN" = false ]; then
        echo "Active Connections: ${connections} (Threshold: ${threshold})" >> "$REPORT_FILE"

        if [ "$connections" -ge "$threshold" ]; then
            echo "  [WARNING] Number of active connections is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Number of active connections is above threshold: ${connections} >= ${threshold}"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Number of active connections is above threshold: ${connections} >= ${threshold}"
            fi

            return 1
        else
            log "INFO" "Number of active connections is normal: ${connections} < ${threshold}"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}Number of active connections is normal:${NC} ${connections} < ${threshold}"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check active connections"
        return 0
    fi
}

# Function to check WordPress response time
check_response_time() {
    local url="$1"
    local threshold="$2"
    local response_time

    if command_exists curl; then
        response_time=$(curl -s -w "%{time_total}\n" -o /dev/null "$url")
    else
        log "WARNING" "curl command not found, skipping response time check"
        echo "  [WARNING] curl command not found, skipping response time check" >> "$REPORT_FILE"
        return 0
    fi

    if [ "$DRY_RUN" = false ]; then
        echo "Response Time: ${response_time}s (Threshold: ${threshold}s)" >> "$REPORT_FILE"

        if (( $(echo "$response_time > $threshold" | bc -l) )); then
            echo "  [WARNING] Response time is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Response time is above threshold: ${response_time}s >= ${threshold}s"

            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Response time is above threshold: ${response_time}s >= ${threshold}s"
            fi

            return 1
        else
            log "INFO" "Response time is normal: ${response_time}s < ${threshold}s"

            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}Response time is normal:${NC} ${response_time}s < ${threshold}s"
            fi

            return 0
        fi
    else
        log "INFO" "Dry run: Would check response time"
        return 0
    fi
}

# Function to check WordPress updates
check_wp_updates() {
    local wp_path="$1"
    local plugin_threshold="$2"
    local theme_threshold="$3"
    local core_threshold="$4"
    
    local plugin_updates=0
    local theme_updates=0
    local core_updates=0
    
    if [ "$DRY_RUN" = false ]; then
        # Check plugin updates
        if plugin_updates_output=$(wp plugin list --update=available --format=count --path="$wp_path" 2>/dev/null); then
            plugin_updates=$plugin_updates_output
        fi
        
        # Check theme updates
        if theme_updates_output=$(wp theme list --update=available --format=count --path="$wp_path" 2>/dev/null); then
            theme_updates=$theme_updates_output
        fi
        
        # Check core updates
        if core_updates_output=$(wp core check-update --format=count --path="$wp_path" 2>/dev/null); then
            core_updates=$core_updates_output
        fi
        
        echo "WordPress Updates:" >> "$REPORT_FILE"
        echo "  Plugins: $plugin_updates (Threshold: $plugin_threshold)" >> "$REPORT_FILE"
        echo "  Themes: $theme_updates (Threshold: $theme_threshold)" >> "$REPORT_FILE"
        echo "  Core: $core_updates (Threshold: $core_threshold)" >> "$REPORT_FILE"
        
        local issues=0
        
        if [ "$plugin_updates" -ge "$plugin_threshold" ]; then
            echo "  [WARNING] Number of plugin updates is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Number of plugin updates is above threshold: ${plugin_updates} >= ${plugin_threshold}"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Number of plugin updates is above threshold: ${plugin_updates} >= ${plugin_threshold}"
            fi
            
            issues=$((issues+1))
        fi
        
        if [ "$theme_updates" -ge "$theme_threshold" ]; then
            echo "  [WARNING] Number of theme updates is above threshold!" >> "$REPORT_FILE"
            log "WARNING" "Number of theme updates is above threshold: ${theme_updates} >= ${theme_threshold}"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} Number of theme updates is above threshold: ${theme_updates} >= ${theme_threshold}"
            fi
            
            issues=$((issues+1))
        fi
        
        if [ "$core_updates" -ge "$core_threshold" ]; then
            echo "  [WARNING] WordPress core update available!" >> "$REPORT_FILE"
            log "WARNING" "WordPress core update available: ${core_updates} >= ${core_threshold}"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} WordPress core update available: ${core_updates} >= ${core_threshold}"
            fi
            
            issues=$((issues+1))
        fi
        
        if [ "$issues" -eq 0 ] && [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
            echo -e "${GREEN}WordPress is up to date.${NC}"
        fi
        
        return $issues
    else
        log "INFO" "Dry run: Would check WordPress updates"
        return 0
    fi
}

# Function to check WordPress error log
check_wp_errors() {
    local wp_path="$1"
    local threshold="$2"
    local error_count=0
    local error_log="$wp_path/wp-content/debug.log"
    
    if [ "$DRY_RUN" = false ]; then
        if [ -f "$error_log" ]; then
            # Count PHP errors in the last 24 hours
            error_count=$(find "$error_log" -mtime -1 -exec cat {} \; | grep -c "PHP")
            
            echo "WordPress Error Log:" >> "$REPORT_FILE"
            echo "  Errors in last 24h: $error_count (Threshold: $threshold)" >> "$REPORT_FILE"
            
            if [ "$error_count" -ge "$threshold" ]; then
                echo "  [WARNING] Number of PHP errors is above threshold!" >> "$REPORT_FILE"
                log "WARNING" "Number of PHP errors is above threshold: ${error_count} >= ${threshold}"
                
                if [ "$QUIET" = false ]; then
                    echo -e "${YELLOW}${BOLD}Warning:${NC} Number of PHP errors is above threshold: ${error_count} >= ${threshold}"
                    echo -e "${YELLOW}Recent errors:${NC}"
                    tail -n 5 "$error_log" | sed 's/^/  /'
                fi
                
                return 1
            else
                log "INFO" "Number of PHP errors is normal: ${error_count} < ${threshold}"
                
                if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                    echo -e "${GREEN}Number of PHP errors is normal:${NC} ${error_count} < ${threshold}"
                fi
                
                return 0
            fi
        else
            echo "  [INFO] WordPress error log not found at $error_log" >> "$REPORT_FILE"
            log "INFO" "WordPress error log not found at $error_log"
            
            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${CYAN}WordPress error log not found at $error_log${NC}"
            fi
            
            return 0
        fi
    else
        log "INFO" "Dry run: Would check WordPress error log"
        return 0
    fi
}

# Function to check WordPress database size
check_wp_db_size() {
    local wp_path="$1"
    local db_size=0
    
    if [ "$DRY_RUN" = false ]; then
        # Get database size
        if db_size_output=$(wp db size --format=tables --path="$wp_path" 2>/dev/null | tail -n 1 | awk '{print $2}'); then
            db_size=$db_size_output
        fi
        
        echo "WordPress Database:" >> "$REPORT_FILE"
        echo "  Size: $db_size" >> "$REPORT_FILE"
        
        log "INFO" "WordPress database size: $db_size"
        
        if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
            echo -e "${GREEN}WordPress database size:${NC} $db_size"
        fi
        
        return 0
    else
        log "INFO" "Dry run: Would check WordPress database size"
        return 0
    fi
}

# Function to check WordPress security
check_wp_security() {
    local wp_path="$1"
    local issues=0
    
    if [ "$DRY_RUN" = false ]; then
        echo "WordPress Security:" >> "$REPORT_FILE"
        
        # Check file permissions
        if ! wp_version=$(wp core version --path="$wp_path" 2>/dev/null); then
            wp_version="Unknown"
        fi
        
        # Check if debug mode is enabled
        if grep -q "define.*WP_DEBUG.*true" "$wp_path/wp-config.php"; then
            echo "  [WARNING] WP_DEBUG is enabled in production!" >> "$REPORT_FILE"
            log "WARNING" "WP_DEBUG is enabled in production"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} WP_DEBUG is enabled in production"
            fi
            
            issues=$((issues+1))
        fi
        
        # Check if file editing is enabled
        if ! grep -q "define.*DISALLOW_FILE_EDIT.*true" "$wp_path/wp-config.php"; then
            echo "  [WARNING] DISALLOW_FILE_EDIT is not set" >> "$REPORT_FILE"
            log "WARNING" "DISALLOW_FILE_EDIT is not set"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} DISALLOW_FILE_EDIT is not set"
            fi
            
            issues=$((issues+1))
        fi
        
        # Check for readme.html
        if [ -f "$wp_path/readme.html" ]; then
            echo "  [WARNING] readme.html exists and could reveal version information" >> "$REPORT_FILE"
            log "WARNING" "readme.html exists and could reveal version information"
            
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}${BOLD}Warning:${NC} readme.html exists and could reveal version information"
            fi
            
            issues=$((issues+1))
        fi
        
        if [ "$issues" -eq 0 ]; then
            echo "  No security issues found" >> "$REPORT_FILE"
            log "INFO" "No WordPress security issues found"
            
            if [ "$QUIET" = false ] && [ "$ALERT_ONLY" = false ]; then
                echo -e "${GREEN}No WordPress security issues found${NC}"
            fi
        fi
        
        return $issues
    else
        log "INFO" "Dry run: Would check WordPress security"
        return 0
    fi
}

# Run all checks
issues=0

echo -e "${CYAN}${BOLD}Starting WordPress monitoring checks...${NC}"
echo "System Information:" >> "$REPORT_FILE"
echo "  Hostname: $(hostname)" >> "$REPORT_FILE"
echo "  WordPress Path: $wpPath" >> "$REPORT_FILE"
echo "  Date: $(date)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Get WordPress URL
if ! wp_url=$(wp option get siteurl --path="$wpPath" 2>/dev/null); then
    wp_url="http://localhost"
    log "WARNING" "Could not determine WordPress URL, using default: $wp_url"
    echo "  [WARNING] Could not determine WordPress URL, using default: $wp_url" >> "$REPORT_FILE"
fi

# System checks
echo "System Checks:" >> "$REPORT_FILE"
check_disk_usage "$wpPath" "$DISK_THRESHOLD" || issues=$((issues+1))
check_cpu_usage "$CPU_THRESHOLD" || issues=$((issues+1))
check_memory_usage "$MEMORY_THRESHOLD" || issues=$((issues+1))
check_load_average "$LOAD_THRESHOLD" || issues=$((issues+1))
check_connections "$CONNECTIONS_THRESHOLD" || issues=$((issues+1))

echo "" >> "$REPORT_FILE"
echo "WordPress Checks:" >> "$REPORT_FILE"
check_response_time "$wp_url" "$RESPONSE_TIME_THRESHOLD" || issues=$((issues+1))
check_wp_updates "$wpPath" "$PLUGIN_UPDATE_THRESHOLD" "$THEME_UPDATE_THRESHOLD" "$CORE_UPDATE_THRESHOLD" || issues=$((issues+1))
check_wp_errors "$wpPath" "$ERROR_LOG_THRESHOLD" || issues=$((issues+1))
check_wp_db_size "$wpPath" || issues=$((issues+1))
check_wp_security "$wpPath" || issues=$((issues+1))

# Collect metrics for CSV
if [ "$DRY_RUN" = false ]; then
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    disk_usage=$(df -h "$wpPath" | awk 'NR==2 {print $5}' | sed 's/%//')
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    memory_usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    load_avg=$(uptime | awk -F'[a-z]:' '{ print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    connections=$(netstat -an | grep ESTABLISHED | wc -l)
    response_time=$(curl -s -w "%{time_total}" -o /dev/null "$wp_url" 2>/dev/null || echo "0")
    uptime=$(uptime -p | sed 's/up //')
    error_count=$([ -f "$wpPath/wp-content/debug.log" ] && find "$wpPath/wp-content/debug.log" -mtime -1 -exec cat {} \; | grep -c "PHP" || echo "0")
    plugin_updates=$(wp plugin list --update=available --format=count --path="$wpPath" 2>/dev/null || echo "0")
    theme_updates=$(wp theme list --update=available --format=count --path="$wpPath" 2>/dev/null || echo "0")
    core_updates=$(wp core check-update --format=count --path="$wpPath" 2>/dev/null || echo "0")
    
    # Write to metrics file
    echo "$timestamp,$disk_usage,$cpu_usage,$memory_usage,$load_avg,$connections,$response_time,$uptime,$error_count,$plugin_updates,$theme_updates,$core_updates" >> "$METRICS_FILE"
fi

# Create summary
SUMMARY_FILE=$(mktemp)
echo "WordPress Monitoring Summary" > "$SUMMARY_FILE"
echo "==========================" >> "$SUMMARY_FILE"
echo "Date: $(date)" >> "$SUMMARY_FILE"
echo "Host: $(hostname)" >> "$SUMMARY_FILE"
echo "WordPress Path: $wpPath" >> "$SUMMARY_FILE"
echo "WordPress URL: $wp_url" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

if [ "$issues" -gt 0 ]; then
    echo "Issues Found: $issues" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    
    # Extract warnings from report
    grep -A 1 "\[WARNING\]" "$REPORT_FILE" | sed 's/--//' >> "$SUMMARY_FILE"
    
    # Send notification
    notify "WARNING" "WordPress monitoring found $issues issues. See attached report for details." "WordPress Monitor" "$SUMMARY_FILE"
    
    echo -e "${YELLOW}${BOLD}Monitoring completed with $issues issues found.${NC}"
    echo -e "${YELLOW}See $REPORT_FILE for details.${NC}"
else
    echo "No issues found. All systems normal." >> "$SUMMARY_FILE"
    
    # Send notification if not in alert-only mode
    if [ "$ALERT_ONLY" = false ]; then
        notify "SUCCESS" "WordPress monitoring completed successfully. All systems normal." "WordPress Monitor" "$SUMMARY_FILE"
    fi
    
    echo -e "${GREEN}${BOLD}Monitoring completed successfully. No issues found.${NC}"
fi

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration $DURATION)
log "INFO" "Monitoring process completed in ${FORMATTED_DURATION}"
update_status "SUCCESS" "Monitoring process completed with $issues issues in ${FORMATTED_DURATION}"

# Clean up
rm -f "$SUMMARY_FILE"

exit $issues
