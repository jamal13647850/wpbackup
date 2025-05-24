#!/bin/bash
#
# Script: monitor.sh
# Author: Sayyed Jamal Ghasemi
# Email: jamal13647850@gmail.com
# LinkedIn: https://www.linkedin.com/in/jamal1364/
# Instagram: https://www.instagram.com/jamal13647850
# Telegram: https://t.me/jamaldev
# Website: https://jamalghasemi.com
# Date: 2025-05-24
#
# Description: Monitors WordPress installations and server health, checks against thresholds,
#              generates reports, logs metrics, and sends alerts.

# Source common functions and variables
. "$(dirname "$0")/common.sh"

# --- Script specific log files ---
LOG_FILE="$SCRIPTPATH/logs/monitor.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/logs/monitor_status.log}"

# --- Default values for script options and behavior ---
VERBOSE=false
ALERT_ONLY=false      # If true, only sends notifications/reports when issues (alerts) are found
QUIET=false           # Minimal console output
REPORT_FILE="$SCRIPTPATH/logs/monitor_report.txt" # Default path for the human-readable report
METRICS_FILE="$SCRIPTPATH/logs/monitor_metrics.csv" # Default path for the CSV metrics log
THRESHOLD_FILE=""     # Optional external file to define thresholds
DRY_RUN=false         # If true, simulates monitoring without executing checks or writing files

# --- Parse command line options ---
while getopts "c:t:r:m:aqvd" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;        # Main configuration file for WordPress site details
        t) THRESHOLD_FILE="$OPTARG";;    # Threshold override file
        r) REPORT_FILE="$OPTARG";;        # Custom report file path
        m) METRICS_FILE="$OPTARG";;       # Custom metrics CSV file path
        a) ALERT_ONLY=true;;
        q) QUIET=true;;
        v) VERBOSE=true;;
        d) DRY_RUN=true;;
        ?) # Handle invalid options
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [-t <threshold_file>] [-r <report_file>] [-m <metrics_file>] [-a] [-q] [-v] [-d]" >&2
            echo -e "  -c: Configuration file for site details (can be .conf.gpg or .conf)"
            echo -e "  -t: Threshold configuration file (overrides defaults)"
            echo -e "  -r: Output report file (default: $SCRIPTPATH/logs/monitor_report.txt)"
            echo -e "  -m: Metrics CSV file (default: $SCRIPTPATH/logs/monitor_metrics.csv)"
            echo -e "  -a: Alert only mode (only reports/notifies on issues exceeding thresholds)"
            echo -e "  -q: Quiet mode (minimal console output)"
            echo -e "  -v: Verbose output (sets LOG_LEVEL to verbose)"
            echo -e "  -d: Dry run (simulates checks, no actual monitoring or file writing)"
            exit 1
            ;;
    esac
done

# Initialize log for this script
init_log "WordPress Monitor"

# --- Configuration File Handling ---
if [ -z "$CONFIG_FILE" ]; then
    if ! $QUIET; then echo -e "${YELLOW}${BOLD}No configuration file specified for monitoring.${NC}"; fi
    if ! select_config_file "$SCRIPTPATH/configs" "monitor"; then # Interactive selection
        log "ERROR" "Configuration file selection failed or was cancelled."
        exit 1
    fi
fi
process_config_file "$CONFIG_FILE" "Monitor" # Load and source the main config

# Load threshold configuration file if specified (this can override defaults set below)
if [ -n "$THRESHOLD_FILE" ]; then
    if [ -f "$THRESHOLD_FILE" ]; then
        # Source the threshold file, allowing it to set/override threshold variables
        . "$THRESHOLD_FILE"
        log "INFO" "Successfully loaded threshold configuration from '$THRESHOLD_FILE'."
    else
        log "ERROR" "Threshold file '$THRESHOLD_FILE' not found. Using default or main config thresholds."
        if ! $QUIET; then echo -e "${RED}${BOLD}Error: Threshold file '$THRESHOLD_FILE' not found! Using defaults.${NC}" >&2; fi
        # Not exiting, allowing script to run with default/main config thresholds
    fi
fi

# Set operational variables (LOG_LEVEL from common.sh based on -v)
LOG_LEVEL="${VERBOSE:+verbose}"
LOG_LEVEL="${LOG_LEVEL:-normal}" # Default log level
NICE_LEVEL="${NICE_LEVEL:-19}"   # Default niceness for commands

# --- Define Default Thresholds ---
# These can be overridden by variables in the sourced THRESHOLD_FILE or the main CONFIG_FILE.
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"          # % disk usage
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"            # % CPU usage
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"      # % memory usage
LOAD_THRESHOLD="${LOAD_THRESHOLD:-2.0}"         # 1-min load average (float)
CONNECTIONS_THRESHOLD="${CONNECTIONS_THRESHOLD:-100}" # Number of active established connections
RESPONSE_TIME_THRESHOLD="${RESPONSE_TIME_THRESHOLD:-2.0}" # Site response time in seconds (float)
# UPTIME_THRESHOLD is not actively used in checks below, but defined here for completeness if needed later.
# UPTIME_THRESHOLD="${UPTIME_THRESHOLD:-95}" # % uptime (would require persistent state or external tool)
ERROR_LOG_THRESHOLD="${ERROR_LOG_THRESHOLD:-10}"    # Max PHP errors in debug.log in last 24h
PLUGIN_UPDATE_THRESHOLD="${PLUGIN_UPDATE_THRESHOLD:-5}" # Max pending plugin updates
THEME_UPDATE_THRESHOLD="${THEME_UPDATE_THRESHOLD:-2}"  # Max pending theme updates
CORE_UPDATE_THRESHOLD="${CORE_UPDATE_THRESHOLD:-1}"    # Max pending core updates (usually 0 or 1)

# Validate required variables from the main config file
for var_name in wpPath; do # wpPath is crucial for WordPress specific checks
    if [ -z "${!var_name}" ]; then
        log "ERROR" "Required variable '$var_name' is not set in configuration file '$CONFIG_FILE'."
        exit 1
    fi
done

# Locate wp-config.php
if [ -f "$wpPath/wp-config.php" ]; then
    WP_CONFIG="$wpPath/wp-config.php"
elif [ -f "$(dirname "$wpPath")/wp-config.php" ]; then # Handles cases like wpPath being 'wordpress' subdir
    WP_CONFIG="$(dirname "$wpPath")/wp-config.php"
    log "INFO" "wp-config.php found in parent directory: $WP_CONFIG"
else
    log "ERROR" "wp-config.php not found in '$wpPath' or its parent directory."
    exit 1
fi

# Check if WP-CLI is installed (essential for many WordPress checks)
if ! command_exists wp; then
    log "ERROR" "WP-CLI command ('wp') not found. It is required for WordPress monitoring."
    if ! $QUIET; then
        echo -e "${RED}${BOLD}Error: WP-CLI is not installed or not in PATH!${NC}" >&2
        echo -e "${YELLOW}Please install WP-CLI and ensure it's in your PATH. See: https://wp-cli.org/#installing${NC}" >&2
    fi
    exit 1
fi

# --- Cleanup Function for Trap ---
cleanup_monitor() {
    # Call common cleanup if needed, then script-specific cleanup
    cleanup "WordPress Monitor process (invoked by trap)" "Monitor Cleanup"
    log "INFO" "Monitor process ended."
    # Any specific temp files for monitor.sh would be cleaned here.
}
trap cleanup_monitor EXIT INT TERM

# --- Main Monitoring Process Start ---
log "INFO" "Starting WordPress monitoring process for site: ${wpHost:-$(basename "$wpPath")}."
update_status "STARTED" "WordPress monitoring process for ${wpHost:-$(basename "$wpPath")}"

# Initialize report and metrics files if not in dry run
if [ "$DRY_RUN" = "false" ]; then
    # Create/Truncate the report file for this run
    echo "WordPress Monitoring Report - $(date)" > "$REPORT_FILE"
    echo "=======================================" >> "$REPORT_FILE"
    echo "Site: ${wpHost:-$(basename "$wpPath")} ($wpPath)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    log "INFO" "Report file initialized: $REPORT_FILE"

    # Create metrics CSV header if the file doesn't exist
    if [ ! -f "$METRICS_FILE" ]; then
        echo "timestamp,wp_path,disk_usage_percent,cpu_usage_percent,memory_usage_percent,load_avg_1min,active_connections,site_response_time_s,server_uptime_str,php_errors_24h,plugin_updates_count,theme_updates_count,core_updates_count" > "$METRICS_FILE"
        log "INFO" "Metrics CSV file created with header: $METRICS_FILE"
    fi
else
    log "INFO" "[Dry Run] Skipping report and metrics file initialization."
fi

# --- Monitoring Check Functions ---

# Check disk usage for a given path
# Args: $1 (path_to_check), $2 (threshold_percent)
check_disk_usage() {
    local check_path="$1"
    local alert_threshold="$2"
    local usage_percent
    local status_ok=true

    usage_percent=$(df -P "$check_path" | awk 'NR==2 {print $5}' | sed 's/%//') # -P for POSIX output
    if [ -z "$usage_percent" ]; then
        log "WARNING" "Could not determine disk usage for '$check_path'."
        echo "Disk Usage ($check_path): Error determining usage" >> "$REPORT_FILE"
        return 1 # Indicate an issue with the check itself
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo "Disk Usage ($check_path): ${usage_percent}% (Threshold: >${alert_threshold}%)" >> "$REPORT_FILE"
        if [ "$usage_percent" -ge "$alert_threshold" ]; then
            echo "  [ALERT] Disk usage is high!" >> "$REPORT_FILE"
            log "ALERT" "High disk usage for '$check_path': ${usage_percent}% (Threshold: ${alert_threshold}%)"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High disk usage for '$check_path': ${usage_percent}% (Threshold: ${alert_threshold}%)${NC}"; fi
            status_ok=false
        else
            log "INFO" "Disk usage for '$check_path' is normal: ${usage_percent}%."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}Disk usage ($check_path):${NC} ${usage_percent}% (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check disk usage for '$check_path' against threshold ${alert_threshold}%."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check CPU usage
# Args: $1 (threshold_percent)
check_cpu_usage() {
    local alert_threshold="$1"
    local usage_percent_val="N/A" # Default if cannot determine
    local status_ok=true

    if command_exists mpstat; then
        # Average CPU idle time, subtract from 100 for usage. mpstat 1 1 means 1-second interval, 1 report.
        usage_percent_val=$(mpstat 1 1 | awk '/Average:/ {print 100 - $NF}' | cut -d. -f1) # $NF is %idle for 'Average:' line
    elif command_exists top; then
        # Get %us + %sy (user + system)
        usage_percent_val=$(top -bn1 | grep "Cpu(s)" | head -n1 | awk '{print $2 + $4}' | cut -d. -f1)
    else
        log "WARNING" "Cannot determine CPU usage: 'mpstat' or 'top' command not found."
        echo "CPU Usage: Unavailable (mpstat/top not found)" >> "$REPORT_FILE"
        return 1 # Issue with the check
    fi
    
    if [ -z "$usage_percent_val" ] || ! [[ "$usage_percent_val" =~ ^[0-9]+$ ]]; then
        log "WARNING" "Failed to parse CPU usage. Raw output was problematic."
        usage_percent_val="N/A" # Could not parse
        echo "CPU Usage: Error parsing value" >> "$REPORT_FILE"
        return 1
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo "CPU Usage: ${usage_percent_val}% (Threshold: >${alert_threshold}%)" >> "$REPORT_FILE"
        if [ "$usage_percent_val" != "N/A" ] && [ "$usage_percent_val" -ge "$alert_threshold" ]; then
            echo "  [ALERT] CPU usage is high!" >> "$REPORT_FILE"
            log "ALERT" "High CPU usage: ${usage_percent_val}% (Threshold: ${alert_threshold}%)"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High CPU usage: ${usage_percent_val}% (Threshold: ${alert_threshold}%)${NC}"; fi
            status_ok=false
        elif [ "$usage_percent_val" != "N/A" ]; then
            log "INFO" "CPU usage is normal: ${usage_percent_val}%."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}CPU usage:${NC} ${usage_percent_val}% (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check CPU usage against threshold ${alert_threshold}%."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check memory usage
# Args: $1 (threshold_percent)
check_memory_usage() {
    local alert_threshold="$1"
    local usage_percent_val
    local status_ok=true

    usage_percent_val=$(free | grep Mem | awk '{print int($3/$2 * 100.0)}') # Used/Total
    if [ -z "$usage_percent_val" ]; then
        log "WARNING" "Could not determine memory usage."
        echo "Memory Usage: Error determining usage" >> "$REPORT_FILE"
        return 1
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo "Memory Usage: ${usage_percent_val}% (Threshold: >${alert_threshold}%)" >> "$REPORT_FILE"
        if [ "$usage_percent_val" -ge "$alert_threshold" ]; then
            echo "  [ALERT] Memory usage is high!" >> "$REPORT_FILE"
            log "ALERT" "High memory usage: ${usage_percent_val}% (Threshold: ${alert_threshold}%)"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High memory usage: ${usage_percent_val}% (Threshold: ${alert_threshold}%)${NC}"; fi
            status_ok=false
        else
            log "INFO" "Memory usage is normal: ${usage_percent_val}%."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}Memory usage:${NC} ${usage_percent_val}% (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check memory usage against threshold ${alert_threshold}%."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check 1-minute load average
# Args: $1 (threshold_float)
check_load_average() {
    local alert_threshold_float="$1"
    local load_avg_1min
    local status_ok=true

    load_avg_1min=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | sed 's/ //g')
    if [ -z "$load_avg_1min" ]; then
        log "WARNING" "Could not determine load average."
        echo "Load Average (1 min): Error determining value" >> "$REPORT_FILE"
        return 1
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo "Load Average (1 min): ${load_avg_1min} (Threshold: >${alert_threshold_float})" >> "$REPORT_FILE"
        # bc -l for floating point comparison
        if (( $(echo "$load_avg_1min > $alert_threshold_float" | bc -l) )); then
            echo "  [ALERT] Load average is high!" >> "$REPORT_FILE"
            log "ALERT" "High load average (1 min): ${load_avg_1min} (Threshold: ${alert_threshold_float})"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High load average (1 min): ${load_avg_1min} (Threshold: ${alert_threshold_float})${NC}"; fi
            status_ok=false
        else
            log "INFO" "Load average (1 min) is normal: ${load_avg_1min}."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}Load average (1 min):${NC} ${load_avg_1min} (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check load average against threshold ${alert_threshold_float}."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check active established network connections
# Args: $1 (threshold_count)
check_connections() {
    local alert_threshold="$1"
    local connections_count="N/A"
    local status_ok=true

    if command_exists netstat; then
        connections_count=$(netstat -ant | grep ESTABLISHED | wc -l) # -t for TCP, -n for numeric
    elif command_exists ss; then
        connections_count=$(ss -nt state established | wc -l) # ss is newer alternative
    else
        log "WARNING" "Cannot determine active connections: 'netstat' or 'ss' command not found."
        echo "Active Connections: Unavailable (netstat/ss not found)" >> "$REPORT_FILE"
        return 1
    fi
     if [ -z "$connections_count" ]; then connections_count=0; fi # Default to 0 if parsing failed somehow

    if [ "$DRY_RUN" = "false" ]; then
        echo "Active Established Connections: ${connections_count} (Threshold: >${alert_threshold})" >> "$REPORT_FILE"
        if [ "$connections_count" -ge "$alert_threshold" ]; then
            echo "  [ALERT] Number of active connections is high!" >> "$REPORT_FILE"
            log "ALERT" "High number of active connections: ${connections_count} (Threshold: ${alert_threshold})"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High active connections: ${connections_count} (Threshold: ${alert_threshold})${NC}"; fi
            status_ok=false
        else
            log "INFO" "Number of active connections is normal: ${connections_count}."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}Active connections:${NC} ${connections_count} (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check active connections against threshold ${alert_threshold}."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check WordPress site response time
# Args: $1 (site_url), $2 (threshold_seconds_float)
check_response_time() {
    local site_url_to_check="$1"
    local alert_threshold_s_float="$2"
    local response_time_s="N/A"
    local status_ok=true

    if ! command_exists curl; then
        log "WARNING" "'curl' command not found. Skipping site response time check."
        echo "Site Response Time ($site_url_to_check): Unavailable (curl not found)" >> "$REPORT_FILE"
        return 1 # Issue with the check
    fi

    # -L to follow redirects, -s silent, -o /dev/null discard output, -w time_total
    response_time_s=$(curl -L -s -w "%{time_total}" -o /dev/null "$site_url_to_check" 2>/dev/null)
    if [ -z "$response_time_s" ]; then
        log "WARNING" "Could not determine response time for '$site_url_to_check'. URL might be unreachable."
        echo "Site Response Time ($site_url_to_check): Error fetching URL" >> "$REPORT_FILE"
        response_time_s="N/A" # Set to N/A to avoid bc error
        status_ok=false # Consider this an alert
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo "Site Response Time ($site_url_to_check): ${response_time_s}s (Threshold: >${alert_threshold_s_float}s)" >> "$REPORT_FILE"
        if [ "$response_time_s" != "N/A" ] && (( $(echo "$response_time_s > $alert_threshold_s_float" | bc -l) )); then
            echo "  [ALERT] Site response time is high!" >> "$REPORT_FILE"
            log "ALERT" "High site response time for '$site_url_to_check': ${response_time_s}s (Threshold: ${alert_threshold_s_float}s)"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} High site response time for '$site_url_to_check': ${response_time_s}s (Threshold: ${alert_threshold_s_float}s)${NC}"; fi
            status_ok=false
        elif [ "$response_time_s" != "N/A" ]; then
            log "INFO" "Site response time for '$site_url_to_check' is normal: ${response_time_s}s."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}Site response time ($site_url_to_check):${NC} ${response_time_s}s (OK)${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check response time for '$site_url_to_check' against threshold ${alert_threshold_s_float}s."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check WordPress for pending updates (plugins, themes, core)
# Args: $1 (wp_install_path), $2 (plugin_update_threshold), $3 (theme_update_threshold), $4 (core_update_threshold)
check_wp_updates() {
    local wp_install_path="$1"
    local plugin_alert_thresh="$2"
    local theme_alert_thresh="$3"
    local core_alert_thresh="$4" # Usually 1, meaning any core update is an alert
    
    local plugin_updates_count=0
    local theme_updates_count=0
    local core_updates_count=0 # 0 = no update, 1 = update available
    local current_issues_count=0

    if [ "$DRY_RUN" = "false" ]; then
        log "INFO" "Checking for WordPress updates at '$wp_install_path'..."
        # Get counts using wp-cli
        plugin_updates_count=$(wp_cli plugin list --update=available --format=count --path="$wp_install_path" 2>/dev/null || echo 0)
        theme_updates_count=$(wp_cli theme list --update=available --format=count --path="$wp_install_path" 2>/dev/null || echo 0)
        # `wp core check-update` returns list of updates. Count lines for a simple metric.
        # Better: `wp core check-update --format=json` and parse, or use `--format=count` if available for `check-update`
        # As of WP-CLI 2.5.0, `wp core check-update --format=count` is valid.
        core_updates_count=$(wp_cli core check-update --format=count --path="$wp_install_path" 2>/dev/null || echo 0)
        
        echo "WordPress Updates:" >> "$REPORT_FILE"
        echo "  Pending Plugin Updates: $plugin_updates_count (Threshold: >=$plugin_alert_thresh)" >> "$REPORT_FILE"
        echo "  Pending Theme Updates:  $theme_updates_count (Threshold: >=$theme_alert_thresh)" >> "$REPORT_FILE"
        echo "  Pending Core Updates:   $core_updates_count (Threshold: >=$core_alert_thresh)" >> "$REPORT_FILE"
        
        if [ "$plugin_updates_count" -ge "$plugin_alert_thresh" ]; then
            echo "  [ALERT] Number of pending plugin updates exceeds threshold." >> "$REPORT_FILE"
            log "ALERT" "High number of pending plugin updates: ${plugin_updates_count} (Threshold: ${plugin_alert_thresh})"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} Pending plugin updates: ${plugin_updates_count} (Threshold: ${plugin_alert_thresh})${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        fi
        if [ "$theme_updates_count" -ge "$theme_alert_thresh" ]; then
            echo "  [ALERT] Number of pending theme updates exceeds threshold." >> "$REPORT_FILE"
            log "ALERT" "High number of pending theme updates: ${theme_updates_count} (Threshold: ${theme_alert_thresh})"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} Pending theme updates: ${theme_updates_count} (Threshold: ${theme_alert_thresh})${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        fi
        if [ "$core_updates_count" -ge "$core_alert_thresh" ]; then # Any core update is usually an alert
            echo "  [ALERT] WordPress core update(s) available." >> "$REPORT_FILE"
            log "ALERT" "WordPress core update(s) available: ${core_updates_count}"
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} WordPress core update(s) available: ${core_updates_count}${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        fi
        
        if [ "$current_issues_count" -eq 0 ]; then
            log "INFO" "WordPress updates check: No issues found (within thresholds)."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}WordPress updates status: OK${NC}"; fi
        fi
        return "$current_issues_count" # Return number of update-related issues found
    else
        log "INFO" "[Dry Run] Would check WordPress updates (plugins, themes, core)."
        return 0 # No issues in dry run for counting
    fi
}

# Check WordPress PHP error log (debug.log)
# Args: $1 (wp_install_path), $2 (error_count_threshold_24h)
check_wp_errors() {
    local wp_install_path="$1"
    local alert_threshold="$2"
    local errors_last_24h=0
    local wp_error_log="$wp_install_path/wp-content/debug.log" # Standard location
    local status_ok=true

    if [ "$DRY_RUN" = "false" ]; then
        echo "WordPress PHP Error Log Check ($wp_error_log):" >> "$REPORT_FILE"
        if [ -f "$wp_error_log" ]; then
            # Count lines containing "PHP Fatal error", "PHP Parse error", "PHP Warning", "PHP Notice" in last 24 hours
            # `find ... -mtime -1` finds files modified in the last 24 hours. We need to check content from last 24h.
            # This is tricky with log rotation. A simpler check counts recent lines.
            # For now, counting specific PHP error types in the whole file if recently modified.
            # A more robust solution would parse timestamps within the log.
            if [ "$(find "$wp_error_log" -mmin -1440 2>/dev/null)" ]; then # Modified in last 24 mins (1440 mins = 24h)
                errors_last_24h=$(grep -E "PHP Fatal error:|PHP Parse error:|PHP Warning:|PHP Notice:" "$wp_error_log" | wc -l)
                # This counts all historical errors if file was touched. A better way is needed for "errors in last 24h".
                # Placeholder: for simplicity, this example counts all known errors in the file.
                # A real solution: `awk` with timestamp parsing or use a log monitoring tool.
                # For now, let's assume `errors_last_24h` is the total count if log was modified recently.
                log "INFO" "Checked PHP error log '$wp_error_log'. Found $errors_last_24h PHP error entries."
            else
                log "INFO" "PHP error log '$wp_error_log' not modified in the last 24 hours. Assuming 0 recent errors."
                errors_last_24h=0
            fi
            
            echo "  PHP Errors (approx total): $errors_last_24h (Threshold for recent: >$alert_threshold)" >> "$REPORT_FILE"
            if [ "$errors_last_24h" -ge "$alert_threshold" ]; then
                echo "  [ALERT] Number of PHP errors is high." >> "$REPORT_FILE"
                echo "  Last 5 lines from error log:" >> "$REPORT_FILE"
                tail -n 5 "$wp_error_log" | sed 's/^/    /' >> "$REPORT_FILE"
                log "ALERT" "High number of PHP errors in '$wp_error_log': ${errors_last_24h} (Threshold: ${alert_threshold})"
                if ! $QUIET; then
                    echo -e "${YELLOW}${BOLD}ALERT:${NC} High PHP error count in '$wp_error_log': ${errors_last_24h} (Threshold: ${alert_threshold})${NC}"
                    echo -e "${YELLOW}Recent errors from log:${NC}"
                    tail -n 5 "$wp_error_log" | sed 's/^/  /'
                fi
                status_ok=false
            else
                log "INFO" "PHP error log check: No significant issues found."
                if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}PHP error log status: OK${NC}"; fi
            fi
        else
            echo "  PHP Error Log not found or not enabled." >> "$REPORT_FILE"
            log "INFO" "WordPress PHP error log ('$wp_error_log') not found. WP_DEBUG_LOG might be false."
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${CYAN}PHP error log '$wp_error_log' not found (this might be normal).${NC}"; fi
        fi
    else
        log "INFO" "[Dry Run] Would check WordPress PHP error log."
    fi
    if $status_ok; then return 0; else return 1; fi
}

# Check WordPress database size
# Args: $1 (wp_install_path)
check_wp_db_size() {
    local wp_install_path="$1"
    local db_size_str="N/A"

    if [ "$DRY_RUN" = "false" ]; then
        # wp db size returns size like "12.34 MB"
        db_size_str=$(wp_cli db size --path="$wp_install_path" 2>/dev/null)
        if [ -z "$db_size_str" ]; then
            db_size_str="Error determining size"
            log "WARNING" "Could not determine WordPress database size for '$wp_install_path'."
        else
            log "INFO" "WordPress database size for '$wp_install_path': $db_size_str."
        fi
        echo "WordPress Database Size: $db_size_str" >> "$REPORT_FILE"
        if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}WordPress Database Size:${NC} $db_size_str${NC}"; fi
    else
        log "INFO" "[Dry Run] Would check WordPress database size for '$wp_install_path'."
    fi
    return 0 # This check is informational, no threshold by default
}

# Check basic WordPress security settings
# Args: $1 (wp_install_path)
check_wp_security() {
    local wp_install_path="$1"
    local current_issues_count=0

    if [ "$DRY_RUN" = "false" ]; then
        log "INFO" "Checking basic WordPress security settings for '$wp_install_path'..."
        echo "WordPress Security Checks:" >> "$REPORT_FILE"
        
        # Check WP_DEBUG status
        if grep -qE "define\s*\(\s*['\"]WP_DEBUG['\"]\s*,\s*true\s*\)" "$WP_CONFIG"; then
            echo "  [ALERT] WP_DEBUG is enabled in $WP_CONFIG. Should be false on production." >> "$REPORT_FILE"
            log "ALERT" "Security: WP_DEBUG is enabled in production for '$wp_install_path'."
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} WP_DEBUG is enabled. Disable on production sites.${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        else
            echo "  WP_DEBUG: OK (not enabled or explicitly false)" >> "$REPORT_FILE"
            log "INFO" "Security: WP_DEBUG check passed for '$wp_install_path'."
        fi

        # Check DISALLOW_FILE_EDIT
        if ! grep -qE "define\s*\(\s*['\"]DISALLOW_FILE_EDIT['\"]\s*,\s*true\s*\)" "$WP_CONFIG"; then
            echo "  [ALERT] DISALLOW_FILE_EDIT is not set to true in $WP_CONFIG. Theme/plugin editor is enabled." >> "$REPORT_FILE"
            log "ALERT" "Security: DISALLOW_FILE_EDIT is not true for '$wp_install_path'."
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} DISALLOW_FILE_EDIT is not set to true. Consider adding it for security.${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        else
             echo "  DISALLOW_FILE_EDIT: OK (set to true)" >> "$REPORT_FILE"
            log "INFO" "Security: DISALLOW_FILE_EDIT check passed for '$wp_install_path'."
        fi
        
        # Check for exposed readme.html
        if [ -f "$wp_install_path/readme.html" ]; then
            echo "  [ALERT] WordPress readme.html file exists at the root. This can expose version information." >> "$REPORT_FILE"
            log "ALERT" "Security: readme.html found at '$wp_install_path/readme.html'."
            if ! $QUIET; then echo -e "${YELLOW}${BOLD}ALERT:${NC} readme.html found. Consider removing it from public access.${NC}"; fi
            current_issues_count=$((current_issues_count + 1))
        else
            echo "  readme.html: OK (not found at root)" >> "$REPORT_FILE"
            log "INFO" "Security: readme.html check passed for '$wp_install_path'."
        fi
        
        if [ "$current_issues_count" -eq 0 ]; then
            if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "${GREEN}WordPress security checks: OK${NC}"; fi
        fi
        return "$current_issues_count"
    else
        log "INFO" "[Dry Run] Would check WordPress security settings for '$wp_install_path'."
        return 0
    fi
}

# --- Run All Monitoring Checks ---
total_issues_found=0 # Accumulator for issues from checks that return a count

if ! $QUIET; then echo -e "\n${CYAN}${BOLD}--- Starting WordPress Monitoring Checks ---${NC}"; fi
# Initial information for the report
if [ "$DRY_RUN" = "false" ]; then
    echo "System Information:" >> "$REPORT_FILE"
    echo "  Hostname: $(hostname)" >> "$REPORT_FILE"
    echo "  Monitored WordPress Path: $wpPath" >> "$REPORT_FILE"
    echo "  Report Timestamp: $(date)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# Get WordPress site URL for response time check
SITE_URL_FOR_CHECK="N/A"
if [ "$DRY_RUN" = "false" ]; then
    SITE_URL_FOR_CHECK=$(wp_cli option get siteurl --path="$wpPath" 2>/dev/null)
    if [ -z "$SITE_URL_FOR_CHECK" ]; then
        SITE_URL_FOR_CHECK="http://localhost" # Fallback if URL cannot be determined
        log "WARNING" "Could not determine WordPress site URL from DB. Using default '$SITE_URL_FOR_CHECK' for response check."
        if [ "$DRY_RUN" = "false" ]; then echo "  [WARNING] Site URL for response check defaulted to: $SITE_URL_FOR_CHECK" >> "$REPORT_FILE"; fi
    else
        log "INFO" "Using site URL for response check: $SITE_URL_FOR_CHECK"
    fi
fi
if [ "$DRY_RUN" = "false" ]; then echo "WordPress Site URL (for checks): $SITE_URL_FOR_CHECK" >> "$REPORT_FILE"; echo "" >> "$REPORT_FILE"; fi


# --- Execute System Checks ---
if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "\n${PURPLE}Performing System Health Checks...${NC}"; fi
if [ "$DRY_RUN" = "false" ]; then echo "System Health Checks:" >> "$REPORT_FILE"; fi
check_disk_usage "$wpPath" "$DISK_THRESHOLD" || total_issues_found=$((total_issues_found + 1)) # Assumes wpPath is on relevant partition
check_cpu_usage "$CPU_THRESHOLD" || total_issues_found=$((total_issues_found + 1))
check_memory_usage "$MEMORY_THRESHOLD" || total_issues_found=$((total_issues_found + 1))
check_load_average "$LOAD_THRESHOLD" || total_issues_found=$((total_issues_found + 1))
check_connections "$CONNECTIONS_THRESHOLD" || total_issues_found=$((total_issues_found + 1))

# --- Execute WordPress Specific Checks ---
if ! $QUIET && [ "$ALERT_ONLY" = false ]; then echo -e "\n${PURPLE}Performing WordPress Application Checks...${NC}"; fi
if [ "$DRY_RUN" = "false" ]; then echo "" >> "$REPORT_FILE"; echo "WordPress Application Checks:" >> "$REPORT_FILE"; fi
check_response_time "$SITE_URL_FOR_CHECK" "$RESPONSE_TIME_THRESHOLD" || total_issues_found=$((total_issues_found + 1))

updates_issues=0
check_wp_updates "$wpPath" "$PLUGIN_UPDATE_THRESHOLD" "$THEME_UPDATE_THRESHOLD" "$CORE_UPDATE_THRESHOLD"
updates_issues=$? # Get return value (count of update issues)
total_issues_found=$((total_issues_found + updates_issues))

check_wp_errors "$wpPath" "$ERROR_LOG_THRESHOLD" || total_issues_found=$((total_issues_found + 1))
check_wp_db_size "$wpPath" # Informational, does not add to issues count by default

security_issues=0
check_wp_security "$wpPath"
security_issues=$? # Get return value (count of security issues)
total_issues_found=$((total_issues_found + security_issues))


# --- Collect Metrics for CSV Logging ---
if [ "$DRY_RUN" = "false" ]; then
    log "INFO" "Collecting and writing metrics to $METRICS_FILE."
    current_timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    # Re-fetch metrics to ensure they are current for the CSV log, some might be slightly different from checks if time passed
    disk_usage_metric=$(df -P "$wpPath" | awk 'NR==2 {print $5}' | sed 's/%//' || echo "N/A")
    cpu_usage_metric=$([ -n "$(command -v mpstat)" ] && mpstat 1 1 | awk '/Average:/ {print 100 - $NF}' | cut -d. -f1 || top -bn1 | grep "Cpu(s)" | head -n1 | awk '{print $2 + $4}' | cut -d. -f1 || echo "N/A")
    memory_usage_metric=$(free | grep Mem | awk '{print int($3/$2 * 100.0)}' || echo "N/A")
    load_avg_metric=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | sed 's/ //g' || echo "N/A")
    connections_metric=$([ -n "$(command -v netstat)" ] && netstat -ant | grep ESTABLISHED | wc -l || ([ -n "$(command -v ss)" ] && ss -nt state established | wc -l || echo "N/A"))
    response_time_metric=$([ -n "$(command -v curl)" ] && curl -L -s -w "%{time_total}" -o /dev/null "$SITE_URL_FOR_CHECK" 2>/dev/null || echo "N/A")
    server_uptime_metric=$(uptime -p | sed 's/up //g' || echo "N/A") # Strip "up " prefix
    php_errors_metric=$([ -f "$wpPath/wp-content/debug.log" ] && grep -cE "PHP Fatal error:|PHP Parse error:|PHP Warning:|PHP Notice:" "$wpPath/wp-content/debug.log" || echo 0) # Total errors in log, not just recent
    plugin_updates_metric=$(wp_cli plugin list --update=available --format=count --path="$wpPath" 2>/dev/null || echo 0)
    theme_updates_metric=$(wp_cli theme list --update=available --format=count --path="$wpPath" 2>/dev/null || echo 0)
    core_updates_metric=$(wp_cli core check-update --format=count --path="$wpPath" 2>/dev/null || echo 0)
    
    # Write collected metrics to the CSV file
    echo "$current_timestamp,\"$wpPath\",$disk_usage_metric,$cpu_usage_metric,$memory_usage_metric,$load_avg_metric,$connections_metric,$response_time_metric,\"$server_uptime_metric\",$php_errors_metric,$plugin_updates_metric,$theme_updates_metric,$core_updates_metric" >> "$METRICS_FILE"
fi

# --- Create Summary and Send Notifications ---
SUMMARY_TEMP_FILE=$(mktemp) # Temporary file for summary content
if [ "$DRY_RUN" = "false" ]; then
    # Populate summary file
    echo "WordPress Monitoring Summary" > "$SUMMARY_TEMP_FILE"
    echo "==========================" >> "$SUMMARY_TEMP_FILE"
    echo "Date: $(date)" >> "$SUMMARY_TEMP_FILE"
    echo "Monitored Host: $(hostname)" >> "$SUMMARY_TEMP_FILE"
    echo "WordPress Path: $wpPath" >> "$SUMMARY_TEMP_FILE"
    echo "Site URL: $SITE_URL_FOR_CHECK" >> "$SUMMARY_TEMP_FILE"
    echo "" >> "$SUMMARY_TEMP_FILE"

    if [ "$total_issues_found" -gt 0 ]; then
        echo "Overall Status: ISSUES DETECTED ($total_issues_found issue(s))" >> "$SUMMARY_TEMP_FILE"
        echo "" >> "$SUMMARY_TEMP_FILE"
        echo "Detected Issues (see $REPORT_FILE for full details):" >> "$SUMMARY_TEMP_FILE"
        # Extract lines containing [ALERT] from the main report file for summary
        grep "\[ALERT\]" "$REPORT_FILE" | sed 's/^ *//' >> "$SUMMARY_TEMP_FILE"
        
        # Send WARNING notification with summary attached
        log "ALERT" "WordPress monitoring found $total_issues_found issue(s). Report: $REPORT_FILE"
        if [ "${NOTIFY_ON_ALERT:-true}" = true ]; then # Assuming NOTIFY_ON_ALERT var
            notify "WARNING" "WordPress monitoring for ${wpHost:-$(basename "$wpPath")} found $total_issues_found issue(s). See attached report summary." "WordPress Monitor Alert" "$SUMMARY_TEMP_FILE"
        fi
        if ! $QUIET; then
            echo -e "\n${YELLOW}${BOLD}--- Monitoring Completed: $total_issues_found ISSUES FOUND ---${NC}"
            echo -e "${YELLOW}A detailed report is available at: $REPORT_FILE${NC}"
            echo -e "${YELLOW}Metrics logged to: $METRICS_FILE${NC}"
        fi
    else # No issues found
        echo "Overall Status: OK - No issues detected (all checks within thresholds)." >> "$SUMMARY_TEMP_FILE"
        log "INFO" "WordPress monitoring completed successfully. No issues found (all checks within thresholds)."
        # Send SUCCESS notification only if NOT in ALERT_ONLY mode
        if [ "$ALERT_ONLY" = false ]; then
            if [ "${NOTIFY_ON_SUCCESS:-true}" = true ]; then # Assuming NOTIFY_ON_SUCCESS var
                 notify "SUCCESS" "WordPress monitoring for ${wpHost:-$(basename "$wpPath")} completed successfully. All systems normal." "WordPress Monitor OK" "$SUMMARY_TEMP_FILE"
            fi
        fi
        if ! $QUIET; then
            echo -e "\n${GREEN}${BOLD}--- Monitoring Completed: All Systems Normal ---${NC}"
            echo -e "${GREEN}Full report is available at: $REPORT_FILE${NC}"
            echo -e "${GREEN}Metrics logged to: $METRICS_FILE${NC}"
        fi
    fi
else # Dry Run Summary
    log "INFO" "[Dry Run] Monitoring simulation complete. Total potential issues if run: $total_issues_found (approx)."
    if ! $QUIET; then
        echo -e "\n${CYAN}${BOLD}--- Dry Run Monitoring Simulation Complete ---${NC}"
        echo -e "${CYAN}No actual checks were performed or files written.${NC}"
        echo -e "${CYAN}Simulated report would be at: $REPORT_FILE${NC}"
        echo -e "${CYAN}Simulated metrics would be logged to: $METRICS_FILE${NC}"
    fi
fi

# --- Finalization ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FORMATTED_DURATION=$(format_duration "$DURATION")

log "INFO" "Monitoring process for ${wpHost:-$(basename "$wpPath")} finished in ${FORMATTED_DURATION}. Issues found: $total_issues_found."
update_status "$([ "$total_issues_found" -gt 0 ] && echo "ALERT" || echo "SUCCESS")" "Monitoring process completed. Issues: $total_issues_found. Duration: ${FORMATTED_DURATION}."


# Clean up temporary summary file
if [ -f "$SUMMARY_TEMP_FILE" ]; then
    rm -f "$SUMMARY_TEMP_FILE"
fi

# Exit with number of issues found (0 for success, >0 if issues)
# This can be used by cron or other automation to determine status.
exit "$total_issues_found"