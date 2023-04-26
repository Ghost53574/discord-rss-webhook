#!/bin/bash

# Description: Post RSS feeds to Discord using a webhook
# License: MIT
# Dependencies: rsstail, pandoc, curl

# Edited by c0z to actually work and look readable
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
PANDOC="$(which pandoc)"
RSSTAIL="$(which rsstail)"
CURL="$(which curl)"
TEE="$(which tee)"

function echo_info ( ) {
    echo -n -e "${GREEN}[${1}]\t[$(date +'%D %T')] ${2}${NC}\n"
}

function echo_warn ( ) {
    echo -n -e "${YELLOW}[${1}]\t[$(date +'%D %T')] ${2}${NC}\n"
}

function echo_fail ( ) {
    echo -n -e "${RED}[${1}]\t[$(date +'%D %T')] ${2}${NC}\n"
}

function check_feeds {
    mkdir -p "${DISCORD_CACHE}"
    cd "${DISCORD_SHARE}/feeds"
    for FEED in *; do
        # unset used variables
        unset WEBHOOK_URL FEED_URL FEED_NAME BOT_USERNAME FEED_COLOR AVATAR_URL POST_LINK NEW_POST_LINK

        source "${DISCORD_SHARE}/config"
        source "${DISCORD_SHARE}/feeds/${FEED}"

        BOT_USERNAME="$(echo "${FEED_NAME}" | tr '-' ' ')"
        echo_info "check_feeds" "Checking ${BOT_USERNAME}..."
        # if last entry from feed stored, get POST_LINK for feed using grep and cut
        if [[ -f "${DISCORD_CACHE}/${FEED_NAME}" ]]; 
        then
            POST_LINK="$(grep -m1 '^Link:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ')"
        fi
        CURL_RET="$(${CURL} -nks "${FEED_URL}" 2>/dev/null)"
        if [[ ! -z "${CURL_RET}" ]];
        then
            # get NEW_POST_LINK for feed using get_feed function, grep, and cut
            NEW_POST_LINK="$(get_feed ${FEED_URL} | grep -m1 '^Link:' | cut -f2- -d' ')"
            # if NEW_POST_LINK not empty and does not match POST_LINK, write latest entry to ~/.cache/discord-rss/$FEED_NAME
            if [[ ! -z "${NEW_POST_LINK}" ]] && [[ ! "${NEW_POST_LINK}" == "${POST_LINK}" ]]; 
            then
                echo_warn "check_feeds" "New post in ${BOT_USERNAME}"
                get_feed "${FEED_URL}" > "${DISCORD_CACHE}/${FEED_NAME}"
                # run a for loop to post to multiple webhook urls if present
                for webhook in $(echo "${WEBHOOK_URL}" | tr ',' '\n'); 
                do
                    post_feed "${webhook}"
                    # sleep 1 to avoid potentially hitting rate limit
                    sleep 1
                done
            fi
        else
            echo_fail "check_feeds" "Feed: ${BOT_USERNAME} is down" | ${TEE} >> "${DISCORD_LOG}"
        fi
    done
    cd
}

# use rsstail to get the latest feed
function get_feed {
    local RSS_URL="$1"
    FEED_CONTENT="$(${RSSTAIL} -1pdlu "${RSS_URL}" -n 1 -b ${CHARACTER_LIMIT} || echo "rsstail failed on ${RSS_URL}" >> "${DISCORD_LOG}")"
    case $? in
        0)
            echo -e "${FEED_CONTENT}" || echo "get_feed errored on ${RSS_URL}" >> "${DISCORD_LOG}"
            unset FEED_CONTENT
            ;;
        *)
            echo_fail "Feed from ${RSS_URL} didn't return any data" | ${TEE} >> "${DISCORD_LOG}"
            ;;
    esac
}
# post feed to Discord using curl
function post_feed {
    local UPLOAD_URL="$1"
    # get feed data for json file using grep and cut
    FEED_TITLE="$(grep -m1 '^Title:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ' | tr '"' "'" | cut -c-255)"
    FEED_LINK="$(grep -m1 '^Link:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ')"
    FEED_DATE="$(grep -m1 '^Pub.date:' "${DISCORD_CACHE}/${FEED_NAME}" | cut -f2- -d' ')"

    if [[ -z "$FEED_DATE" ]]; 
    then
        FEED_DATE="$(date -u)"
    fi
    # try to find picture links for thumbnail in embed
    THUMBNAIL_URL="$(rsstail -d1u "${FEED_URL}" -n 1 | grep -om1 'http.*\.png\|http.*\.jpg')"

    case "${THUMBNAIL_URL}" in
        *youtube*) 
            THUMBNAIL_URL="$(echo "${THUMBNAIL_URL}" | cut -f3 -d'"')"
        ;;
        *) 
            THUMBNAIL_URL="$(echo "${THUMBNAIL_URL}" | cut -f1 -d' ' | tr -d '"')"
        ;;
    esac
    # if no THUMBNAIL_URL found, just use 1x1 dummy image
    if [[ "${THUMBNAIL_URL}" =~ "@" ]]; 
    then
        THUMBNAIL_URL="https://dummyimage.com/1x1/000/fff"
        IMAGE_TYPE="thumbnail"
    elif [[ -z "$THUMBNAIL_URL" ]]; 
    then
        THUMBNAIL_URL="https://dummyimage.com/1x1/000/fff"
        IMAGE_TYPE="thumbnail"
    else
        if [[ "$FEED_NAME" == "xkcd" ]]; 
        then
            IMAGE_TYPE="image"
        else
            IMAGE_TYPE="thumbnail"
        fi
    fi
    # use grep to get rid of everything except the description then use sed to get rid of the Description label and replace new lines with '\n'
    # also use recode to turn html escapes into normal symbols then use sed to replace a couple of weird ones that recode adds
    case "${FEED_NAME}" in
        *)
            FEED_DESC="$(cat "${DISCORD_CACHE}/${FEED_NAME}" | grep -v '^Title:' | grep -v '^Link:' | grep -v '^Pub.date:' | sed "s%Description:%%" | ${PANDOC} --wrap=none -s -f html -t markdown | grep -v '^<\!-' | tr -d '\\' | sed 's%{.*}%%g;s%!\[.*\](.*)%%g' | sed 's%^\[$%%g;s%^Watch video%\[Watch video%g' | grep . --color=never | sed 's%^.*%&\\n%g' | tr -d '\n' | tr '"' "'" | tr '\t' ' ' | tr -d '\r' | grep -v '^:::')"
            ;;
    esac
    # check amount of characters; assume that more than 650 is trunicated and add '[...]'
    if [[ $(echo ${FEED_DESC} | wc -c) -gt 1100 ]]; 
    then
        FEED_DESC="$(echo "${FEED_DESC}" | rev | cut -f2- -d' ' | rev) [...]"
    fi
    FEED_DESC="$(echo "${FEED_DESC}" | tr -d '\n' | tr -d \' | tr -d \")"
    # skip posting certain feeds
    case "${FEED_TITLE}" in
        # dont post LWN.net paid articles
        \[\$\]*)
            echo_warn "post_feed" "Skipping feed ${BOT_USERNAME} title ${FEED_TITLE}"
            ;;
        *)
            # use curl to send /tmp/discord-rss.json to WEBHOOK_URL
            TIMESTAMP_DATE="$(date -d "${FEED_DATE}" '+%Y-%m-%dT%TZ' -u)"
            JSON_DATA="{ \"username\": \"Rss Feed\", \"avatar_url\": \"${AVATAR_URL}\", \"embeds\": [{ \"title\": \"${FEED_TITLE}\",\"url\": \"${FEED_LINK}\",\"description\": \"${FEED_DESC}\",\"color\": \"${FEED_COLOR}\",\"timestamp\":\"${TIMESTAMP_DATE}\",\"${IMAGE_TYPE}\": {\"url\":\"${THUMBNAIL_URL}\"},\"author\": {\"name\": \"${BOT_USERNAME}\",\"url\": \"${FEED_LINK}\",\"icon_url\":\"${AVATAR_URL}\"}}]}"
            echo "${JSON_DATA}" | ${CURL} -iL -X POST -H "Content-Type: application/json" --data-binary @- "${UPLOAD_URL}" >> "${DISCORD_LOG}" || echo_fail "post_feed" "Feed: ${FEED_NAME} failed the curl post request" >> "${DISCORD_LOG}"
            echo
            ;;
    esac
    # unset used variables
    unset FEED_TITLE FEED_LINK FEED_DESC THUMBNAIL_URL
}

# setup environment
function setup_env {
    local PWD="$(pwd)"
    # create config if not found
    if [[ ! -d "${DISCORD_FEEDS}" ]] || [[ ! -f "${DISCORD_SHARE}/config" ]]; 
    then
        echo_info "setup_env" "Creating config" 
        mkdir -p "${DISCORD_FEEDS}"
        cat > "${DISCORD_SHARE}/config" << EOF
# default webhook url to use for feeds.
# if webhook url is set in feed config file, that url will be used instead
WEBHOOK_URL="https://discordapp.com/api/webhooks/channelidhere/tokenhere?wait=true"
# time to sleep between feed check cycles
RSS_CHECK_TIME=45
# max amount of characters to be sent in embed description (Discord's max is 2048)
CHARACTER_LIMIT=1800
EOF
    fi
    # create example feed config and exit if none exist
    if [[ $(ls -Cw1 "${DISCORD_FEEDS}" | wc -l) -eq 0 ]]; 
    then
        echo_info "setup_env" "Creating example feed" 
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
    echo_fail "setup_env" "No feeds found in ${DISCORD_FEEDS}; see example in ${DISCORD_SHARE}/Example-Feed'"
    exit 0
    fi
    # create images directory
    if [[ ! -d "${DISCORD_AVATARS}" ]];
    then
        echo_info "setup_env" "Creating images directory in ${DISCORD_SHARE}" 
        mkdir -p "${DISCORD_AVATARS}"
        cp ./*.png "${DISCORD_AVATARS}/"    
    fi
    if [[ ! -d "${DISCORD_LOGS}" ]];
    then
        echo_info "setup_env" "Creating logs directory in ${DISCORD_SHARE}" 
        mkdir -p "${DISCORD_LOGS}"   
    fi
}
# setup environment
setup_env
source "${DISCORD_SHARE}/config"
# start while loop that runs every RSS_CHECK_TIME seconds
CURRENT_LOOP=${RSS_CHECK_TIME}
while true; do
    if [[ "${CURRENT_LOOP}" == "${RSS_CHECK_TIME}" ]]; then
        echo_fail "main" "Checking RSS feeds..."
        check_feeds
        echo_info "main" "Sleeping for ${RSS_CHECK_TIME} seconds..."
        CURRENT_LOOP=0
    else
        sleep 1
        ((CURRENT_LOOP++))
    fi
done
echo ""
exit 0
