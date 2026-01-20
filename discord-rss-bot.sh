#!/bin/bash
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

DISCORD_CACHE="${PWD}/.cache/discord-rss"
DISCORD_SHARE="${PWD}/.local/share/discord-rss-bot"
DISCORD_FEEDS="${DISCORD_SHARE}/feeds"
DISCORD_AVATARS="${DISCORD_SHARE}/avatars"
DISCORD_LOGS="${DISCORD_SHARE}/logs"
DISCORD_LOG="${DISCORD_LOGS}/${TIMESTAMP}.log"
DISCORD_STATUS="${DISCORD_SHARE}/status.json"
RSSTAIL="$(which rsstail)"

DEFAULT_FETCH_TIMEOUT=15

# Helper function to center text within a given field width
function center_text() {
    local text="$1"
    local width="$2"
    local text_length=${#text}

    if [[ $text_length -ge $width ]]; then
        echo "$text"
        return
    fi

    local total_padding=$((width - text_length))
    local left_padding=$((total_padding / 2))
    local right_padding=$((total_padding - left_padding))

    printf "%*s%s%*s" $left_padding "" "$text" $right_padding ""
}

_log_exception() {
    (
        BASHLOG_FILE=0
        BASHLOG_JSON=0
        BASHLOG_SYSLOG=0
        log error "Logging exception: $*"
    )
}

function log_message() {
    local level="$1"
    shift
    local message="$*"

    local upper
    upper="$(echo "$level" | awk '{print toupper($0)}')"

    local timestamp_fmt="${BASHLOG_DATE_FORMAT:-+%F %T}"
    local timestamp
    timestamp="$(date "${timestamp_fmt}")"
    local timestamp_s
    timestamp_s="$(date +%s)"

    local pid="$$"
    local debug_level="${DEBUG:-0}"

    local file="${BASHLOG_FILE:-1}"
    local file_path="${LOG_FILE:-${BASHLOG_FILE_PATH:-/tmp/$(basename "$0").log}}"

    local json="${BASHLOG_JSON:-0}"
    local json_path="${BASHLOG_JSON_PATH:-/tmp/$(basename "$0").log.json}"

    local syslog="${BASHLOG_SYSLOG:-0}"
    local tag="${BASHLOG_SYSLOG_TAG:-$(basename "$0")}"
    local facility="${BASHLOG_SYSLOG_FACILITY:-local0}"

    declare -A severities=(
        [DEBUG]=7
        [INFO]=6
        [SUCCESS]=6
        [NOTICE]=5
        [WARN]=4
        [ERROR]=3
        [CRIT]=2
        [ALERT]=1
        [EMERG]=0
    )

    local severity="${severities[$upper]:-3}"

    if [[ "$debug_level" -gt 0 || "$severity" -lt 7 ]];
    then
        if [[ "$syslog" -eq 1 ]];
        then
            logger \
                --id="$pid" \
                -t "$tag" \
                -p "$facility.$severity" \
                "$upper: $message" \
                || _log_exception "syslog failed: $message"
        fi

        if [[ "$file" -eq 1 ]];
        then
            echo "[$timestamp] [$upper] $message" >> "$file_path" \
                || _log_exception "file log failed: $file_path"
        fi

        if [[ "$json" -eq 1 ]];
        then
            printf '{"timestamp":"%s","level":"%s","message":"%s"}\n' \
                "$timestamp_s" "$upper" "$message" >> "$json_path" \
                || _log_exception "json log failed: $json_path"
        fi
    fi

    local NC='\033[0m'
    local RED='\033[31m'
    local YELLOW='\033[33m'
    local BLUE='\033[34m'
    local BOLD_GREEN='\033[1;32m'
    local WHITE='\033[1;37m'

    local colour="$NC"
    case "$upper" in
        DEBUG)   colour="$BLUE" ;;
        INFO)    colour="$WHITE" ;;
        SUCCESS) colour="$BOLD_GREEN" ;;
        WARN)    colour="$YELLOW" ;;
        ERROR)   colour="$RED" ;;
    esac

    local std_line="${colour}[$timestamp] [$upper] $message${NC}"

    # ---- Console behavior ----
    case "$upper" in
        DEBUG)
            [[ "$debug_level" -gt 0 ]] && echo -e "$std_line" >&2
            ;;
        ERROR)
            echo -e "$std_line" >&2
            if [[ "$debug_level" -gt 0 ]];
            then
                echo "Dropping to debug shell (exit 0 to continue):" >&2
                bash || exit "$?"
            fi
            ;;
        *)
            echo -e "$std_line" >&2
            ;;
    esac
}

# Function to check for updates in all RSS feeds
function check_feeds {
    local FEED POST_LINK NEW_POST_LINK feed_content

    mkdir -p "${DISCORD_CACHE}"

    # Track statistics
    local total_feeds=0
    local failed_feeds=0
    local updated_feeds=0

    # Start with clean state
    log_message "INFO" "check_feeds" "Starting feed check cycle"

    # Trap errors to prevent script termination
    # trap 'log_message "ERROR" "check_feeds" "Caught error during feed processing, continuing with next feed"' ERR

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
        # shellcheck source=/dev/null
        source "${DISCORD_SHARE}/config"
        # shellcheck source=/dev/null
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

            # Atomically save the new feed content to avoid race conditions
            # Write to temp file first, then move atomically
            local temp_cache="${DISCORD_CACHE}/${FEED_NAME}.tmp"
            echo "${feed_content}" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^\[INFO\]' | grep -v '^\[WARN\]' | grep -v '^\[ERROR\]' > "${temp_cache}"
            mv -f "${temp_cache}" "${DISCORD_CACHE}/${FEED_NAME}"

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
    local feed_content=""
    local timeout="${DEFAULT_FETCH_TIMEOUT}"
    local exit_code first_non_empty_line wait_time

    log_message "INFO" "get_feed" "Fetching feed from ${RSS_URL}"

    # Try up to max_retries times to get the feed
    while [[ $retry_count -lt $max_retries ]]; do
        # Clear previous content
        feed_content=""

        # Execute with timeout and capture output (no eval needed)
        feed_content="$(timeout "${timeout}" "${RSSTAIL}" -1pdlu "${RSS_URL}" -n 1 -b "${CHARACTER_LIMIT}" 2>/dev/null)"
        exit_code=$?

        # Handle timeout (exit code 124) and other errors
        if [[ $exit_code -eq 124 ]]; then
            log_message "ERROR" "get_feed" "Feed fetch timed out after ${timeout}s: ${RSS_URL}"
        elif [[ $exit_code -ne 0 ]]; then
            log_message "ERROR" "get_feed" "Failed to fetch feed: ${RSS_URL} (exit code: ${exit_code})"
        fi

        # Check if we got valid content
        if [[ $exit_code -eq 0 && -n "${feed_content}" ]]; then
            # Find the first non-empty line
            local first_non_empty_line
            first_non_empty_line="$(echo "${feed_content}" | grep -m1 -v '^[[:space:]]*$')"
            if [[ "${first_non_empty_line}" =~ ^[[:space:]]*Title: ]]; then
                log_message "INFO" "get_feed" "Successfully fetched and validated feed content"
                echo -e "${feed_content}"
                return 0
            else
                log_message "ERROR" "get_feed" "Fetched content does not match expected format (missing Title): ${first_non_empty_line}"
            fi
        fi

        # Increment retry counter
        retry_count=$((retry_count+1))

        if [[ $retry_count -lt $max_retries ]]; then
            local wait_time=$((retry_count * 3))  # Progressive backoff: 3s, 6s, 9s
            log_message "WARN" "get_feed" "Retry ${retry_count}/${max_retries} for ${FEED_NAME} in ${wait_time}s (exit code: ${exit_code}, content length: ${#feed_content})"
            sleep $wait_time
        else
            log_message "ERROR" "get_feed" "Failed after ${max_retries} attempts: ${FEED_NAME} (${RSS_URL}) - final exit_code: ${exit_code}"
        fi
    done

    # If we get here, all retries failed
    echo "FETCH_FAILED"
    return 1
}
# Post feed to Discord using curl with improved error handling
function post_feed {
    local UPLOAD_URL="${1}"
    local FEED_TITLE FEED_LINK FEED_DATE THUMBNAIL_CMD_RESULT THUMBNAIL_URL IMAGE_TYPE FEED_DESC
    local max_retries retry_count success response http_code body retry_after

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
    if THUMBNAIL_CMD_RESULT="$(rsstail -d1u "${FEED_URL}" -n 1 2>&1)"; then
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

    log_message "WARN" "[post_feed]: Feed name lookup: ${FEED_NAME} -> ${DISCORD_CACHE}/${FEED_NAME}"

    # Extract and format description based on feed type
    FEED_DATA="$(cat "${DISCORD_CACHE}/${FEED_NAME}")"
    FEED_INFO="$(echo "${FEED_DATA}" | grep -v '^Title:' | grep -v '^Link:' | grep -v '^Pub.date:')"
    FEED_DESC="$(echo "${FEED_INFO}" | grep -v '^\[INFO\]' | grep -v '^\[WARN\]' | grep -v '^\[ERROR\]' | sed "s%Description:%%" | pandoc --wrap=none -s -f html -t markdown | grep -v '^<\!-' | tr -d '\\' | sed 's%{.*}%%g;s%!\[.*\](.*)%%g' | sed 's%^\[$%%g;s%^Watch video%\[Watch video%g' | grep . --color=never | sed 's%^.*%&\\n%g' | tr -d '\n' | tr '"' "'" | tr '\t' ' ' | tr -d '\r' | grep -v '^:::')"
    # Clean up any remaining log messages and unwanted patterns
    FEED_DESC="$(echo "${FEED_DESC}" | sed '/^\[\ +INFO/d; /^\[\ +WARN/d; /^\[\ +ERROR\]/d; /^$/d')"

    # Truncate long descriptions
    if [[ ${#FEED_DESC} -gt 1100 ]]; then
        FEED_DESC="$(echo "${FEED_DESC}" | rev | cut -f2- -d' ' | rev) [...]"
    fi

    # Check if we should skip posting based on feed rules
    if [[ "${FEED_TITLE}" =~ ^\\\[\\\$\].*$ ]]; then
        # Don't post paid articles
        log_message "WARN" "post_feed" "Skipping paid article: ${FEED_TITLE}"
        return 0
    fi

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
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')

        case "$http_code" in
            200|204)
                # Success
                log_message "SUCCESS" "post_feed" "Successfully posted to Discord"
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

    # Clean up and reset
    rm -f "/tmp/discord-rss.json"
    unset FEED_TITLE FEED_LINK FEED_DESC THUMBNAIL_URL

    return 0
}
# JSON escape function to properly escape strings for JSON
function json_escape() {
    local input="$1"
    # Handle all JSON special characters properly
    # Order matters: backslash first, then other escapes
    printf '%s' "$input" | \
        sed 's/\\/\\\\/g' | \
        sed 's/"/\\"/g' | \
        sed 's/	/\\t/g' | \
        sed ':a;N;$!ba;s/\n/\\n/g' | \
        sed 's/\r/\\r/g' | \
        tr -d '\000-\037'
}

# create json file containing embed data to upload to webhook URL
function create_json() {
    local escaped_title escaped_desc escaped_username timestamp

    # Escape all dynamic content for JSON
    escaped_title="$(json_escape "${FEED_TITLE}")"
    escaped_desc="$(json_escape "${FEED_DESC}")"
    escaped_username="$(json_escape "${BOT_USERNAME}")"

    # Try to parse date, fall back to current time if parsing fails
    if ! timestamp=$(date -d "${FEED_DATE}" '+%Y-%m-%dT%TZ' -u 2>/dev/null); then
        timestamp=$(date '+%Y-%m-%dT%TZ' -u)
        log_message "WARN" "create_json" "Failed to parse date '${FEED_DATE}', using current time"
    fi

    cat > /tmp/discord-rss.json << EOL
{
    "username": "Rss Feed",
    "avatar_url": "${AVATAR_URL}",
    "embeds": [{
        "title": "${escaped_title}",
        "url": "${FEED_LINK}",
        "description": "${escaped_desc}",
        "color": ${FEED_COLOR},
        "timestamp": "${timestamp}",
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
    if [[ ! -d "${DISCORD_LOGS}" ]]; then
        mkdir -p "${DISCORD_LOGS}"
        log_message "INFO" "setup_env" "Created logs directory: ${DISCORD_LOGS}"
    fi
    if [[ ! -f ${DISCORD_LOG} ]]; then
        log_message "INFO" "setup_env" "Creating log file: ${DISCORD_LOG}"
        touch "${DISCORD_LOG}"
    fi
    # Create the main directory structure
    for dir in "${DISCORD_FEEDS}" "${DISCORD_AVATARS}" "${DISCORD_CACHE}"; do
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
    #if [[ -n "$(ls *.png 2>/dev/null)" ]]; then
    #    log_message "INFO" "setup_env" "Copying PNG files to avatars directory"
    #    cp -f *.png "${DISCORD_AVATARS}/" 2>/dev/null || true
    #fi

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
    local feed_count
    feed_count=$(find "${DISCORD_FEEDS}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

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
    local feed_count
    feed_count=$(find "${DISCORD_FEEDS}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

    # Count recent posts (in the last 24 hours)
    local recent_posts
    recent_posts=$(grep -l "New post in" "${DISCORD_LOGS}"/*.log 2>/dev/null | wc -l)

    # Calculate uptime - extract start_time first to avoid read/write conflict
    local saved_start_time
    saved_start_time=$(grep "start_time" "${DISCORD_STATUS}" | cut -d'"' -f4 2>/dev/null || echo "")
    local start_time
    start_time=$(date -d "$saved_start_time" +%s 2>/dev/null || date +%s)
    local current_time
    current_time=$(date +%s)
    local uptime=$((current_time - start_time))

    # Count errors in logs
    local errors
    errors=$(grep -c "ERROR" "${DISCORD_LOG}" 2>/dev/null || echo "0")

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
    # shellcheck source=/dev/null
    source "${DISCORD_SHARE}/config"

    # Set trap for clean exit
    # trap cleanup EXIT INT TERM

    # Set trap for errors but don't exit
    # trap 'log_message "ERROR" "main" "Caught error in main loop, continuing..."' ERR

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
