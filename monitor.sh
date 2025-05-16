#!/bin/bash
# Load common functions and variables
. "$(dirname "$0")/common.sh"

# Set log files
LOG_FILE="$SCRIPTPATH/monitor.log"
STATUS_LOG="${STATUS_LOG:-$SCRIPTPATH/monitor_status.log}"

# Initialize variables with default values
DRY_RUN=false
VERBOSE=false
CHECK_UPTIME=true
CHECK_DISK=true
CHECK_MEMORY=true
CHECK_LOAD=true
CHECK_SERVICES=true
CHECK_WP_CRON=true
CHECK_SSL=true
THRESHOLD_DISK=90  # Warning when disk usage is above 90%
THRESHOLD_MEMORY=90  # Warning when memory usage is above 90%
THRESHOLD_LOAD=2  # Warning when system load is above 2x number of cores
SERVICES_TO_CHECK="nginx,mysql,php-fpm"  # Services to check
NOTIFY_ON_FAILURE=true  # Send notification on issue detection

# Parse command line options
while getopts "c:dvusmlpht:r:a:n" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG";;
        d) DRY_RUN=true;;
        v) VERBOSE=true; LOG_LEVEL="verbose";;
        u) CHECK_UPTIME=true;;
        s) CHECK_SSL=true;;
        m) CHECK_MEMORY=true;;
        l) CHECK_LOAD=true;;
        p) CHECK_SERVICES=true;;
        t) THRESHOLD_DISK="$OPTARG";;
        r) THRESHOLD_MEMORY="$OPTARG";;
        a) THRESHOLD_LOAD="$OPTARG";;
        n) NOTIFY_ON_FAILURE=true;;
        h) 
            echo -e "${BLUE}${BOLD}WordPress Monitoring Script${NC}"
            echo -e "${CYAN}Usage:${NC} $0 [options]"
            echo -e "${CYAN}Options:${NC}"
            echo -e "  -c <config_file>     Configuration file"
            echo -e "  -d                   Dry run (no actual changes)"
            echo -e "  -v                   Verbose output"
            echo -e "  -u                   Check site uptime"
            echo -e "  -s                   Check SSL certificate"
            echo -e "  -m                   Check memory usage"
            echo -e "  -l                   Check system load"
            echo -e "  -p                   Check service status"
            echo -e "  -t <threshold>       Disk space threshold percentage (default: 90)"
            echo -e "  -r <threshold>       Memory threshold percentage (default: 90)"
            echo -e "  -a <threshold>       Load threshold (default: 2)"
            echo -e "  -n                   Send notification on issue detection"
            echo -e "  -h                   Display this help message"
            exit 0
            ;;
        ?) 
            echo -e "${RED}${BOLD}Usage:${NC} $0 -c <config_file> [options]" >&2
            exit 1
            ;;
    esac
done

# If no configuration file is specified, prompt for selection
if [ -z "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}${BOLD}No configuration file specified.${NC}"
    if ! select_config_file "$SCRIPTPATH/configs" "monitor"; then
        echo -e "${RED}${BOLD}Error: Configuration file selection failed!${NC}" >&2
        exit 1
    fi
elif [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}${BOLD}Error: Configuration file $CONFIG_FILE not found!${NC}" >&2
    exit 1
else
    echo -e "${GREEN}Using configuration file: ${BOLD}$(basename "$CONFIG_FILE")${NC}"
fi

# Source the config file directly
. "$CONFIG_FILE"

# Validate required configuration variables
for var in wpPath; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}${BOLD}Error: Required variable $var is not set in $CONFIG_FILE!${NC}" >&2
        exit 1
    fi
done

# Custom cleanup function for monitoring
cleanup_monitor() {
    cleanup "Monitoring process" "Monitoring"
}
trap cleanup_monitor INT TERM

# Start monitoring process
log "INFO" "Starting monitoring process for $DIR"
update_status "STARTED" "Monitoring process for $DIR"

# Array to store detected issues
ISSUES=()

# Check site uptime
check_site_uptime() {
    local site_url
    
    # Try to get site URL from WordPress
    if [ -d "$wpPath" ]; then
        site_url=$(wp option get siteurl --path="$wpPath" 2>/dev/null)
        
        if [ -z "$site_url" ]; then
            # If we can't get URL from WordPress, use config variable
            site_url="${SITE_URL:-http://localhost}"
        fi
        
        echo -e "${CYAN}${BOLD}Checking site availability at $site_url...${NC}"
        
        # Check site availability
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$site_url")
        
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            echo -e "${GREEN}Site is accessible (HTTP code: $http_code)${NC}"
            log "INFO" "Site is accessible (HTTP code: $http_code)"
        else
            echo -e "${RED}${BOLD}Site is not accessible! (HTTP code: $http_code)${NC}"
            log "ERROR" "Site is not accessible! (HTTP code: $http_code)"
            ISSUES+=("Site is not accessible (HTTP code: $http_code)")
        fi
    else
        echo -e "${YELLOW}${BOLD}WordPress path is not valid. Cannot check site availability.${NC}"
        log "WARNING" "WordPress path is not valid. Cannot check site availability."
    fi
}

# Check disk space
check_disk_space() {
    echo -e "${CYAN}${BOLD}Checking disk space...${NC}"
    
    # Get disk usage percentage
    local disk_usage=$(df -h "$wpPath" | grep -v Filesystem | awk '{print $5}' | tr -d '%')
    
    if [ "$disk_usage" -lt "$THRESHOLD_DISK" ]; then
        echo -e "${GREEN}Disk space is sufficient (Usage: ${disk_usage}%)${NC}"
        log "INFO" "Disk space is sufficient (Usage: ${disk_usage}%)"
    else
        echo -e "${RED}${BOLD}Warning: Disk space is low! (Usage: ${disk_usage}%)${NC}"
        log "ERROR" "Warning: Disk space is low! (Usage: ${disk_usage}%)"
        ISSUES+=("Disk space is low (Usage: ${disk_usage}%)")
    fi
}

# Check memory usage
check_memory_usage() {
    echo -e "${CYAN}${BOLD}Checking memory usage...${NC}"
    
    # Get memory usage percentage
    local memory_usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    
    if [ "$memory_usage" -lt "$THRESHOLD_MEMORY" ]; then
        echo -e "${GREEN}Memory usage is normal (Usage: ${memory_usage}%)${NC}"
        log "INFO" "Memory usage is normal (Usage: ${memory_usage}%)"
    else
        echo -e "${RED}${BOLD}Warning: High memory usage! (Usage: ${memory_usage}%)${NC}"
        log "ERROR" "Warning: High memory usage! (Usage: ${memory_usage}%)"
        ISSUES+=("High memory usage (Usage: ${memory_usage}%)")
    fi
}

# Check system load
check_system_load() {
    echo -e "${CYAN}${BOLD}Checking system load...${NC}"
    
    # Get current load and number of CPU cores
    local load=$(uptime | awk -F'[a-z]:' '{ print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    local cores=$(nproc)
    local load_per_core=$(awk "BEGIN {printf \"%.2f\", $load / $cores}")
    
    if (( $(echo "$load_per_core < $THRESHOLD_LOAD" | bc -l) )); then
        echo -e "${GREEN}System load is normal (Load: ${load_per_core} per core)${NC}"
        log "INFO" "System load is normal (Load: ${load_per_core} per core)"
    else
        echo -e "${RED}${BOLD}Warning: High system load! (Load: ${load_per_core} per core)${NC}"
        log "ERROR" "Warning: High system load! (Load: ${load_per_core} per core)"
        ISSUES+=("High system load (Load: ${load_per_core} per core)")
    fi
}

# Check service status
check_services() {
    echo -e "${CYAN}${BOLD}Checking service status...${NC}"
    
    IFS=',' read -ra SERVICES <<< "$SERVICES_TO_CHECK"
    for service in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo -e "${GREEN}Service $service is running${NC}"
            log "INFO" "Service $service is running"
        else
            echo -e "${RED}${BOLD}Warning: Service $service is not running!${NC}"
            log "ERROR" "Warning: Service $service is not running!"
            ISSUES+=("Service $service is not running")
        fi
    done
}

# Check WordPress cron status
check_wp_cron() {
    echo -e "${CYAN}${BOLD}Checking WordPress cron status...${NC}"
    
    if [ -d "$wpPath" ]; then
        local cron_events=$(wp cron event list --format=count --path="$wpPath" 2>/dev/null)
        
        if [ -z "$cron_events" ]; then
            echo -e "${YELLOW}${BOLD}Could not check WordPress cron events${NC}"
            log "WARNING" "Could not check WordPress cron events"
        elif [ "$cron_events" -gt 0 ]; then
            echo -e "${GREEN}WordPress cron has $cron_events scheduled events${NC}"
            log "INFO" "WordPress cron has $cron_events scheduled events"
            
            # Check for missed cron events
            local missed_events=$(wp cron event list --format=count --due-now --path="$wpPath" 2>/dev/null)
            if [ "$missed_events" -gt 5 ]; then
                echo -e "${RED}${BOLD}Warning: $missed_events WordPress cron events are due now!${NC}"
                log "ERROR" "Warning: $missed_events WordPress cron events are due now!"
                ISSUES+=("$missed_events WordPress cron events are due now")
            fi
        else
            echo -e "${YELLOW}${BOLD}No WordPress cron events scheduled${NC}"
            log "WARNING" "No WordPress cron events scheduled"
        fi
    else
        echo -e "${YELLOW}${BOLD}WordPress path is not valid. Cannot check cron status.${NC}"
        log "WARNING" "WordPress path is not valid. Cannot check cron status."
    fi
}

# Check SSL certificate
check_ssl_certificate() {
    echo -e "${CYAN}${BOLD}Checking SSL certificate...${NC}"
    
    # Try to get site URL from WordPress
    if [ -d "$wpPath" ]; then
        local site_url=$(wp option get siteurl --path="$wpPath" 2>/dev/null)
        
        if [ -z "$site_url" ]; then
            # If we can't get URL from WordPress, use config variable
            site_url="${SITE_URL:-http://localhost}"
        fi
        
        # Check if site uses HTTPS
        if [[ "$site_url" == https://* ]]; then
            local domain=$(echo "$site_url" | awk -F/ '{print $3}')
            
            # Get certificate expiration date
            local ssl_info=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)
            
            if [ -n "$ssl_info" ]; then
                local expiry_date=$(echo "$ssl_info" | sed 's/notAfter=//g')
                local expiry_epoch=$(date -d "$expiry_date" +%s)
                local current_epoch=$(date +%s)
                local days_remaining=$(( (expiry_epoch - current_epoch) / 86400 ))
                
                if [ "$days_remaining" -lt 0 ]; then
                    echo -e "${RED}${BOLD}Warning: SSL certificate has expired!${NC}"
                    log "ERROR" "Warning: SSL certificate has expired!"
                    ISSUES+=("SSL certificate has expired")
                elif [ "$days_remaining" -lt 14 ]; then
                    echo -e "${RED}${BOLD}Warning: SSL certificate expires in $days_remaining days!${NC}"
                    log "ERROR" "Warning: SSL certificate expires in $days_remaining days!"
                    ISSUES+=("SSL certificate expires in $days_remaining days")
                else
                    echo -e "${GREEN}SSL certificate is valid for $days_remaining more days${NC}"
                    log "INFO" "SSL certificate is valid for $days_remaining more days"
                fi
            else
                echo -e "${RED}${BOLD}Warning: Could not retrieve SSL certificate information!${NC}"
                log "ERROR" "Warning: Could not retrieve SSL certificate information!"
                ISSUES+=("Could not retrieve SSL certificate information")
            fi
        else
            echo -e "${YELLOW}${BOLD}Site is not using HTTPS${NC}"
            log "WARNING" "Site is not using HTTPS"
        fi
    else
        echo -e "${YELLOW}${BOLD}WordPress path is not valid. Cannot check SSL certificate.${NC}"
        log "WARNING" "WordPress path is not valid. Cannot check SSL certificate."
    fi
}

# Run checks based on configuration
if [ "$CHECK_UPTIME" = true ]; then
    check_site_uptime
fi

if [ "$CHECK_DISK" = true ]; then
    check_disk_space
fi

if [ "$CHECK_MEMORY" = true ]; then
    check_memory_usage
fi

if [ "$CHECK_LOAD" = true ]; then
    check_system_load
fi

if [ "$CHECK_SERVICES" = true ]; then
    check_services
fi

if [ "$CHECK_WP_CRON" = true ]; then
    check_wp_cron
fi

if [ "$CHECK_SSL" = true ]; then
    check_ssl_certificate
fi

# Generate report
echo -e "\n${CYAN}${BOLD}=== Monitoring Report ====${NC}"
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}No issues detected${NC}"
    log "INFO" "No issues detected"
    update_status "SUCCESS" "Monitoring completed - No issues detected"
    
    if [ "$NOTIFY_ON_FAILURE" = true ]; then
        notify "SUCCESS" "WordPress monitoring completed - No issues detected" "Monitoring"
    fi
else
    echo -e "${RED}${BOLD}${#ISSUES[@]} issues detected:${NC}"
    for issue in "${ISSUES[@]}"; do
        echo -e "${RED}- $issue${NC}"
    done
    
    log "ERROR" "${#ISSUES[@]} issues detected"
    update_status "WARNING" "Monitoring completed - ${#ISSUES[@]} issues detected"
    
    if [ "$NOTIFY_ON_FAILURE" = true ]; then
        notify "WARNING" "WordPress monitoring detected ${#ISSUES[@]} issues: ${ISSUES[*]}" "Monitoring"
    fi
fi

# Complete monitoring process
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "INFO" "Monitoring process completed in ${DURATION}s"
echo -e "${GREEN}Monitoring completed in ${DURATION} seconds${NC}"
