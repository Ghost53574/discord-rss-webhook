#!/bin/bash
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

GREEN='\e[0;32m'
YELLOW='\e[1;33m'
RED='\e[0;31m'
NC='\e[0m'

DISCORD_CACHE="${HOME}/.cache/discord-rss"
DISCORD_SHARE="${HOME}/.local/share/discord-rss-bot"
DISCORD_FEEDS="${DISCORD_SHARE}/feeds"
DISCORD_AVATARS="${DISCORD_SHARE}/avatars"
DISCORD_LOGS="${DISCORD_SHARE}/logs"
DISCORD_LOG="${DISCORD_LOGS}/${TIMESTAMP}.log"
DISCORD_STATUS="${DISCORD_SHARE}/status.json"
RSSTAIL="$(which rsstail)"

# Unified logging function for consistent formatting
function log_message() {
    local level="$1"
    local component="$2"
    local message="$3"
    
    local color=""
    case "$level" in
        INFO)  color="${GREEN}" ;;
        WARN)  color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
        *)     color="${NC}" ;;
    esac
    
    local timestamp="$(date +'%D %T')"
    echo -n -e "${color}[${level}]\t[${component}]\t\t[${timestamp}]\t${message}${NC}\n"
    echo "[${level}] [${component}] [${timestamp}] ${message}" >> "${DISCORD_LOG}"
}

# Function to check for updates in all RSS feeds
function check_feeds {
    mkdir -p "${DISCORD_CACHE}"
    
    # Track statistics
    local total_feeds=0
    local failed_feeds=0
    local updated_feeds=0
    
    # Start with clean state
    log_message "INFO" "check_feeds" "Starting feed check cycle"
    
    # Trap errors to prevent script termination
    #trap 'log_message "ERROR" "check_feeds" "Caught error during feed processing, continuing with next feed"' ERR
    
    # Process each feed
    cd "${DISCORD_SHARE}/feeds" || {
        log_message "ERROR" "check_feeds" "Failed to change to feeds directory"
        return 1
    }
    
    for FEED in *; do
        # Skip if not a file
        [[ ! -f "$FEED" ]] && continue
        
        # Skip files that contain RSS data (safety check)
        if grep -q "^Title:" "$FEED" 2>/dev/null; then
            log_message "WARN" "check_feeds" "Skipping RSS cache file in feeds directory: ${FEED}"
            continue
        fi
        
        total_feeds=$((total_feeds+1))
        
        # Reset variables for this feed
        unset WEBHOOK_URL FEED_URL FEED_NAME BOT_USERNAME FEED_COLOR AVATAR_URL POST_LINK NEW_POST_LINK
        
        # Load configurations
        source "${DISCORD_SHARE}/config"
        source "${DISCORD_SHARE}/feeds/${FEED}"
        
        # Skip if missing required config
        if [[ -z "${FEED_URL}" || -z "$FEED_NAME" ]]; then
            log_message "ERROR" "check_feeds" "Feed ${FEED} missing required configuration (FEED_URL or FEED_NAME)"
            failed_feeds=$((failed_feeds+1))
            continue
        fi
        
        BOT_USERNAME="$(echo "${FEED_NAME}" | tr '-' ' ')"
        log_message "INFO" "check_feeds" "Checking ${BOT_USERNAME}"
        
        # Get last post link if available
        if [[ -f "${DISCORD_CACHE}/${FEED_NAME}" ]]; then
            POST_LINK="$(grep -m1 '^Link:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ')"
        fi
        # Get new feed content
        local feed_content
        feed_content="$(get_feed "${FEED_URL}")"

        # Check if feed fetch failed
        if [[ "${feed_content}" == "FETCH_FAILED" ]]; then
            log_message "ERROR" "check_feeds" "Failed to fetch feed: ${BOT_USERNAME}"
            failed_feeds=$((failed_feeds+1))
            continue
        fi
        
        # Extract new post link
        NEW_POST_LINK="$(echo "${feed_content}" | grep -m1 '^Link:' | cut -f2- -d' ')"
        
        # Check if we have a new post
        if [[ -n "${NEW_POST_LINK}" && "${NEW_POST_LINK}" != "${POST_LINK}" ]]; then
            log_message "WARN" "check_feeds" "New post in ${BOT_USERNAME}"
            updated_feeds=$((updated_feeds+1))
            
            # Clean and save the new feed content (remove any log messages and ANSI codes)
            echo "${feed_content}" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^\[INFO\]' | grep -v '^\[WARN\]' | grep -v '^\[ERROR\]' > "${DISCORD_CACHE}/${FEED_NAME}"
            
            # Post to all webhook URLs
            for webhook in $(echo "${WEBHOOK_URL}" | tr ',' '\n'); do
                # Skip empty webhooks
                [[ -z "$webhook" ]] && continue
                
                post_feed "${webhook}"
                
                # Sleep to avoid rate limiting
                sleep 1
            done
        fi
    done
    
    # Log summary
    log_message "INFO" "check_feeds" "Completed feed check: ${total_feeds} total, ${updated_feeds} updated, ${failed_feeds} failed"
    
    # Reset trap and return to previous directory
    trap - ERR
    cd - > /dev/null || true
    
    # Always return success to keep main loop running
    return 0
}

# Use rsstail to get the latest feed with improved error handling and retries
function get_feed {
    local RSS_URL="${1}"
    local max_retries=3
    local retry_count=0
    local FEED_CONTENT=""
    
    log_message "INFO" "get_feed" "Fetching feed from ${RSS_URL}"
    
    # Try up to max_retries times to get the feed
    while [[ $retry_count -lt $max_retries ]]; do
        # Clear previous content
        FEED_CONTENT=""
        
        # Call rsstail based on feed type - capture only stdout, redirect stderr to /dev/null
        case "${FEED_NAME}" in
            # Reverse output for feeds that are weird and backwards
            openSUSE-Factory|openSUSE-Support|openSUSE-Bugs)
                FEED_CONTENT="$(${RSSTAIL} -1pdlru "${RSS_URL}" -n 1 -b ${CHARACTER_LIMIT})"
                ;;
            *)
                FEED_CONTENT="$(${RSSTAIL} -1pdlu "${RSS_URL}" -n 1 -b ${CHARACTER_LIMIT})"
                ;;
        esac
        
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            log_message "ERROR" "get_feed" "Failed to fetch feed: ${RSS_URL} (exit code: ${exit_code})"
            retry_count=$((retry_count+1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_message "WARN" "get_feed" "Retrying (${retry_count}/${max_retries}) in 2 seconds..."
                sleep 2
            else
                log_message "ERROR" "get_feed" "Max retries reached for ${RSS_URL}, giving up"
                return 1
            fi
            continue
        fi
        
        # Check if content is non-empty
        if [[ -n "${FEED_CONTENT}" ]]; then
            # Find the first non-empty line
            local first_non_empty_line="$(echo "${FEED_CONTENT}" | grep -m1 -v '^[[:space:]]*$')"
            if [[ "${first_non_empty_line}" =~ ^[[:space:]]*Title: ]]; then
                log_message "INFO" "get_feed" "Successfully fetched feed content"
            else
                log_message "ERROR" "get_feed" "Fetched content does not match expected format (missing Title): ${first_non_empty_line}"
                unset FEED_CONTENT
                retry_count=$((retry_count+1))
                if [[ $retry_count -lt $max_retries ]]; then
                    log_message "WARN" "get_feed" "Retrying (${retry_count}/${max_retries}) in 2 seconds..."
                    sleep 2
                    continue
                else
                    log_message "ERROR" "get_feed" "Max retries reached for ${RSS_URL}, giving up"
                    return 1
                fi
            fi
        fi
        
        # Check if we got valid content (should start with Title: for RSS feeds)
        # Make the regex more robust by allowing for potential whitespace
        if [[ $exit_code -eq 0 && -n "${FEED_CONTENT}" && "${FEED_CONTENT}" =~ ^[[:space:]]*Title: ]]; then
            log_message "INFO" "get_feed" "Successfully validated content format"
            # Success - return the content
            echo -e "${FEED_CONTENT}"
            return 0
        fi
        
        # Log the failure with more detail
        retry_count=$((retry_count+1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_message "WARN" "get_feed" "Retry ${retry_count}/${max_retries} for ${FEED_NAME}: ${RSS_URL} (exit code: ${exit_code}, content empty: $([[ -z "${FEED_CONTENT}" ]] && echo "yes" || echo "no"), regex match: $([[ "${FEED_CONTENT}" =~ ^[[:space:]]*Title: ]] && echo "yes" || echo "no"))"
            sleep 2
        else
            log_message "ERROR" "get_feed" "Failed after ${max_retries} attempts: ${FEED_NAME} (${RSS_URL}) - exit_code: ${exit_code}, content_length: ${#FEED_CONTENT}"
        fi
    done
    
    # If we get here, all retries failed
    echo "FETCH_FAILED"
    return 1
}
# Post feed to Discord using curl with improved error handling
function post_feed {
    local UPLOAD_URL="${1}"
    
    log_message "INFO" "post_feed" "Processing feed ${FEED_NAME} for posting to Discord"
    
    # Extract feed data
    FEED_TITLE="$(grep -m1 '^Title:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ' | tr '"' "'" | cut -c-255)"
    FEED_LINK="$(grep -m1 '^Link:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ')"
    FEED_DATE="$(grep -m1 '^Pub.date:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ' | sed 's/\x1b\[[0-9;]*m//g')"

    # Use current date if no date found
    if [[ -z "$FEED_DATE" ]]; then
        FEED_DATE="$(date -u)"
    fi
    
    # Try to find picture links for thumbnail with error handling
    local THUMBNAIL_CMD_RESULT
    THUMBNAIL_CMD_RESULT="$(rsstail -d1u "${FEED_URL}" -n 1 2>&1)"
    
    if [[ $? -eq 0 ]]; then
        THUMBNAIL_URL="$(echo "$THUMBNAIL_CMD_RESULT" | grep -om1 'http.*\.png\|http.*\.jpg')"
        
        case "${THUMBNAIL_URL}" in
            *youtube*) 
                THUMBNAIL_URL="$(echo "${THUMBNAIL_URL}" | cut -f3 -d'"')"
            ;;
            *) 
                THUMBNAIL_URL="$(echo "${THUMBNAIL_URL}" | cut -f1 -d' ' | tr -d '"')"
            ;;
        esac
    else
        log_message "WARN" "post_feed" "Failed to get thumbnail, using default image"
        THUMBNAIL_URL=""
    fi
    
    # If no valid thumbnail found, use default
    if [[ "${THUMBNAIL_URL}" =~ "@" ]] || [[ -z "$THUMBNAIL_URL" ]]; then
        THUMBNAIL_URL="https://dummyimage.com/1x1/000/fff"
        IMAGE_TYPE="thumbnail"
    else
        # Use full image for xkcd, thumbnail for others
        IMAGE_TYPE=$([ "$FEED_NAME" == "xkcd" ] && echo "image" || echo "thumbnail")
    fi
    
    # Extract and format description based on feed type
    case "${FEED_NAME}" in
        # Get rid of new lines in LWN posts; too messy with them
        LWN)
            FEED_DESC="$(cat "${DISCORD_CACHE}/${FEED_NAME}" | grep -v '^Title:' | grep -v '^Link:' | grep -v '^Pub.date:' | sed "s%Description:%%" | pandoc --wrap=none -s -f html -t markdown | tr -d '\\' | sed 's%{.*}%%g;s%!\[.*\](.*)%%g' | tr '\n' ' ' | tr '"' "'" | tr '\t' ' ' | tr -d '\r' | grep . --color=never)"
            ;;
        # Find description from HTML for xkcd
        xkcd)
            FEED_DESC="$(cat "${DISCORD_CACHE}/${FEED_NAME}" | grep -v '^Title:' | grep -v '^Link:' | grep -v '^Pub.date:' | sed "s%Description:%%" | pandoc --wrap=none -s -f html -t markdown | cut -f2- -d'(' | cut -f2- -d' ' | grep '^"' | cut -f2 -d'"')"
            ;;
        *)
            FEED_DESC="$(cat "${DISCORD_CACHE}/${FEED_NAME}" | grep -v '^Title:' | grep -v '^Link:' | grep -v '^Pub.date:' | grep -v '^\[INFO\]' | grep -v '^\[WARN\]' | grep -v '^\[ERROR\]' | sed "s%Description:%%" | pandoc --wrap=none -s -f html -t markdown | grep -v '^<\!-' | tr -d '\\' | sed 's%{.*}%%g;s%!\[.*\](.*)%%g' | sed 's%^\[$%%g;s%^Watch video%\[Watch video%g' | grep . --color=never | sed 's%^.*%&\\n%g' | tr -d '\n' | tr '"' "'" | tr '\t' ' ' | tr -d '\r' | grep -v '^:::')"
            ;;
    esac

    # Clean up any remaining log messages and unwanted patterns
    FEED_DESC="$(echo "${FEED_DESC}" | sed '/^\[INFO\]/d; /^\[WARN\]/d; /^\[ERROR\]/d; /^$/d')"
    
    # Truncate long descriptions
    if [[ $(echo "${FEED_DESC}" | wc -c) -gt 1100 ]]; then
        FEED_DESC="$(echo "${FEED_DESC}" | rev | cut -f2- -d' ' | rev) [...]"
    fi
    
    # Check if we should skip posting based on feed rules
    if [[ "${FEED_TITLE}" =~ ^\\\[\\\$\].*$ ]]; then
        # Don't post LWN.net paid articles
        log_message "WARN" "post_feed" "Skipping paid article: ${FEED_TITLE}"
        return 0
    fi
    
    # Special handling for different feed types
    local should_post=true
    
    if [[ "${FEED_NAME}" == "openSUSE-Bugs" && ! "${FEED_TITLE}" =~ .*New:.* ]]; then
        log_message "WARN" "post_feed" "Skipping non-new bug post: ${FEED_TITLE}"
        should_post=false
    elif [[ ("${FEED_NAME}" == "openSUSE-Factory" || "${FEED_NAME}" == "openSUSE-Support") && "${FEED_TITLE}" =~ .*Re:.* ]]; then
        log_message "WARN" "post_feed" "Skipping reply post: ${FEED_TITLE}"
        should_post=false
    elif [[ "${FEED_NAME}" == "LKML.ORG" && "${FEED_TITLE}" =~ ^Re:.* ]]; then
        log_message "WARN" "post_feed" "Skipping reply post: ${FEED_TITLE}"
        should_post=false
    fi
    
    # Special enhancements for certain feeds
    if [[ "${FEED_NAME}" == "openSUSE-Factory" && "${FEED_TITLE}" =~ "New Tumbleweed snapshot" ]]; then
        AVATAR_URL="https://cdn.discordapp.com/emojis/426479426474213414.gif?v=1"
        FEED_DESC='**New openSUSE Tumbleweed snapshot released!  Time to `dup`!**'
    fi
    
    # Post to Discord if not skipped
    if [[ "$should_post" == true ]]; then
        # Create Discord-formatted JSON
        create_json
        
        # Send to Discord with improved error handling
        log_message "INFO" "post_feed" "Posting to Discord webhook"
        
        # Try to post to Discord with retries
        local max_retries=3
        local retry_count=0
        local success=false
        
        while [[ $retry_count -lt $max_retries && "$success" == false ]]; do
            # Send to Discord and capture response with status code
            local response
            response=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST -d @"/tmp/discord-rss.json" "${UPLOAD_URL}" 2>&1)
            
            # Extract HTTP code from last line
            local http_code=$(echo "$response" | tail -n1)
            local body=$(echo "$response" | sed '$d')
            
            case "$http_code" in
                200|204)
                    # Success
                    log_message "INFO" "post_feed" "Successfully posted to Discord"
                    success=true
                    ;;
                429)
                    # Rate limited
                    local retry_after
                    retry_after=$(echo "$body" | grep -o '"retry_after":[0-9]*\.' | grep -o '[0-9]*')
                    retry_after=${retry_after:-5}
                    
                    log_message "WARN" "post_feed" "Rate limited by Discord, waiting ${retry_after}s before retry"
                    sleep "$retry_after"
                    ;;
                404)
                    log_message "ERROR" "post_feed" "Webhook not found (404): ${UPLOAD_URL}"
                    return 1
                    ;;
                *)
                    log_message "ERROR" "post_feed" "Discord API error ($http_code): $body"
                    
                    # Wait briefly before retrying
                    sleep 2
                    ;;
            esac
            
            retry_count=$((retry_count+1))
            
            if [[ "$success" == false && $retry_count -lt $max_retries ]]; then
                log_message "WARN" "post_feed" "Retrying Discord post (${retry_count}/${max_retries})"
            fi
        done
        
        if [[ "$success" == false ]]; then
            log_message "ERROR" "post_feed" "Failed to post to Discord after ${max_retries} attempts"
        fi
    fi
    
    # Clean up and reset
    rm -f "/tmp/discord-rss.json"
    unset FEED_TITLE FEED_LINK FEED_DESC THUMBNAIL_URL
    
    return 0
}
# JSON escape function to properly escape strings for JSON
function json_escape() {
    local input="$1"
    # Escape backslashes first, then quotes, then newlines and carriage returns
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//'
}

# create json file containing embed data to upload to webhook URL
function create_json {
    # Escape all dynamic content for JSON
    local escaped_title="$(json_escape "${FEED_TITLE}")"
    local escaped_desc="$(json_escape "${FEED_DESC}")"
    local escaped_username="$(json_escape "${BOT_USERNAME}")"
    
    cat > /tmp/discord-rss.json << EOL
{
    "username": "Rss Feed",
    "avatar_url": "${AVATAR_URL}",
    "embeds": [{
        "title": "${escaped_title}",
        "url": "${FEED_LINK}",
        "description": "${escaped_desc}",
        "color": ${FEED_COLOR},
        "timestamp": "$(date -d "${FEED_DATE}" '+%Y-%m-%dT%TZ' -u)",
        "${IMAGE_TYPE}": {
          "url": "${THUMBNAIL_URL}"
        },
        "author": {
            "name": "${escaped_username}",
            "url": "${FEED_LINK}",
            "icon_url": "${AVATAR_URL}"
        }
    }]
}
EOL
}
# Setup environment for the bot with improved directory creation and initialization
function setup_env {
    # Create the main directory structure
    for dir in "${DISCORD_FEEDS}" "${DISCORD_AVATARS}" "${DISCORD_LOGS}" "${DISCORD_CACHE}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_message "INFO" "setup_env" "Created directory: $dir"
        fi
    done
    
    # Create default config file if not found
    if [[ ! -f "${DISCORD_SHARE}/config" ]]; then
        log_message "INFO" "setup_env" "Creating default config file"
        cat > "${DISCORD_SHARE}/config" << EOF
# default webhook url to use for feeds.
# if webhook url is set in feed config file, that url will be used instead
WEBHOOK_URL="https://discordapp.com/api/webhooks/channelidhere/tokenhere?wait=true"
# time to sleep between feed check cycles
RSS_CHECK_TIME=180
# max amount of characters to be sent in embed description (Discord's max is 2048)
CHARACTER_LIMIT=1800
# number of retries for failed feed fetches
MAX_FETCH_RETRIES=3
EOF
    fi
    
    # Check for dependencies
    local missing_deps=()
    
    for dep in rsstail pandoc curl; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_message "ERROR" "setup_env" "Missing required dependencies: ${missing_deps[*]}"
        log_message "INFO" "setup_env" "Please install the missing dependencies and try again"
        exit 1
    fi
    
    # Create example feed config and exit if none exist
    if [[ $(ls -A "${DISCORD_FEEDS}" 2>/dev/null | wc -l) -eq 0 ]]; then
        log_message "INFO" "setup_env" "Creating example feed configuration"
        cat > "${DISCORD_SHARE}/Example-Feed" << EOF
# webhook url to use for this feed; leave blank to use default
WEBHOOK_URL=""
# must be a valid RSS feed that is readable by 'rsstail'
FEED_URL="https://www.phoronix.com/rss.php"
# will be used as the bot's username when posting; '-' in the 'name' will be replaced with a space
FEED_NAME="Phoronix-News"
# 'color' must be in decimal format; see https://www.mathsisfun.com/hexadecimal-decimal-colors.html
FEED_COLOR=6523985
# 'avatar_url' must be a valid image acceptable for Discord avatars
AVATAR_URL="https://raw.githubusercontent.com/simoniz0r/discord-rss-bot/master/avatars/phoronix.png"
EOF
        log_message "ERROR" "setup_env" "No feeds found in ${DISCORD_FEEDS}; see example in ${DISCORD_SHARE}/Example-Feed"
        exit 0
    fi
    
    # Copy any PNG files to the avatars directory if needed
    if [[ -n "$(ls *.png 2>/dev/null)" ]]; then
        log_message "INFO" "setup_env" "Copying PNG files to avatars directory"
        cp -f *.png "${DISCORD_AVATARS}/" 2>/dev/null || true
    fi
    
    # Set up log rotation - keep only the most recent 30 logs
    if [[ $(ls -A "${DISCORD_LOGS}" 2>/dev/null | wc -l) -gt 30 ]]; then
        log_message "INFO" "setup_env" "Performing log rotation"
        ls -t "${DISCORD_LOGS}"/*.log | tail -n +31 | xargs rm -f
    fi
    
    # Create initial status file
    create_status_file
    
    log_message "INFO" "setup_env" "Environment setup complete"
}

# Create a status file with bot information
function create_status_file {
    log_message "INFO" "status" "Creating status file"
    
    # Count feeds
    local feed_count=$(ls -A "${DISCORD_FEEDS}" 2>/dev/null | wc -l)
    
    # Create status file
    cat > "${DISCORD_STATUS}" << EOF
{
    "status": "running",
    "version": "1.1.0",
    "timestamp": "$(date +'%Y-%m-%d %H:%M:%S')",
    "pid": $$,
    "feeds_configured": ${feed_count},
    "check_interval": ${RSS_CHECK_TIME:-180},
    "character_limit": ${CHARACTER_LIMIT:-1800},
    "start_time": "$(date +'%Y-%m-%d %H:%M:%S')"
}
EOF
}
# Update the status file with current information
function update_status_file() {
    # Count feeds
    local feed_count=$(ls -A "${DISCORD_FEEDS}" 2>/dev/null | wc -l)
    
    # Count recent posts (in the last 24 hours)
    local recent_posts=$(grep -l "New post in" "${DISCORD_LOGS}"/*.log 2>/dev/null | wc -l)
    
    # Calculate uptime
    local start_time=$(date -d "$(grep "start_time" "${DISCORD_STATUS}" | cut -d'"' -f4)" +%s 2>/dev/null || echo "$(date +%s)")
    local current_time=$(date +%s)
    local uptime=$((current_time - start_time))
    
    # Count errors in logs
    local errors=$(grep -c "ERROR" "${DISCORD_LOG}" 2>/dev/null || echo "0")
    
    # Update status file
    cat > "${DISCORD_STATUS}" << EOF
{
    "status": "running",
    "version": "1.1.0",
    "timestamp": "$(date +'%Y-%m-%d %H:%M:%S')",
    "pid": $$,
    "uptime_seconds": ${uptime},
    "feeds_configured": ${feed_count},
    "posts_processed_24h": ${recent_posts},
    "check_interval": ${RSS_CHECK_TIME:-180},
    "character_limit": ${CHARACTER_LIMIT:-1800},
    "last_check": "$(date +'%Y-%m-%d %H:%M:%S')",
    "errors": ${errors},
    "start_time": "$(grep "start_time" "${DISCORD_STATUS}" | cut -d'"' -f4 2>/dev/null || echo "$(date +'%Y-%m-%d %H:%M:%S')")"
}
EOF
}

# Watchdog function to keep track of script health
function update_watchdog() {
    echo "$CURRENT_LOOP" > "${DISCORD_SHARE}/watchdog.timestamp"
}

# Cleanup function to run on script exit
function cleanup() {
    log_message "INFO" "main" "Shutting down discord-rss-bot"
    
    # Update status to indicate we're stopping
    cat > "${DISCORD_STATUS}" << EOF
{
    "status": "stopped",
    "version": "1.1.0",
    "timestamp": "$(date +'%Y-%m-%d %H:%M:%S')",
    "pid": $$,
    "shutdown_reason": "Normal shutdown or signal received"
}
EOF
    
    # Remove watchdog file
    rm -f "${DISCORD_SHARE}/watchdog.timestamp"
    
    exit 0
}

# Main function to run the RSS bot
function main() {
    # Setup environment and load config
    setup_env
    source "${DISCORD_SHARE}/config"
    
    # Set trap for clean exit
    trap cleanup EXIT INT TERM
    
    # Set trap for errors but don't exit
    trap 'log_message "ERROR" "main" "Caught error in main loop, continuing..."' ERR
    
    # Start with an immediate check
    CURRENT_LOOP=$RSS_CHECK_TIME
    
    # Log startup
    log_message "INFO" "main" "Discord RSS Bot started - checking feeds every ${RSS_CHECK_TIME} seconds"
    
    # Main loop
    while true; do
        # Update watchdog file
        update_watchdog
        
        if [[ "$CURRENT_LOOP" -ge "$RSS_CHECK_TIME" ]]; then
            # Time to check feeds
            log_message "INFO" "main" "Checking RSS feeds..."
            
            # Store start time for this check
            local check_start=$(date +%s)
            
            # Run feed checks
            check_feeds
            
            # Update status file
            update_status_file
            
            # Calculate check duration
            local check_duration=$(($(date +%s) - check_start))
            log_message "INFO" "main" "Feed check completed in ${check_duration} seconds"
            
            # Reset loop counter
            CURRENT_LOOP=0
            
            # Log that we're sleeping
            log_message "INFO" "main" "Sleeping for ${RSS_CHECK_TIME} seconds until next check"
        else
            # Sleep for 1 second
            sleep 1
            ((CURRENT_LOOP++))
            
            # Update status every 60 seconds
            if [[ $((CURRENT_LOOP % 60)) -eq 0 ]]; then
                update_status_file
            fi
        fi
    done
}

# Start the bot
main
