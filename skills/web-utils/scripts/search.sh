#!/bin/bash

# Configuration
SEARXNG_URL="${SEARXNG_API_URL:-http://searxng:8080}"

QUERY="$1"

if [ -z "$QUERY" ]; then
    echo "Usage: $0 <query>"
    exit 1
fi

# URL Encode function
urlencode() {
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

ENCODED_QUERY=$(urlencode "$QUERY")
FULL_URL="${SEARXNG_URL}/search?q=${ENCODED_QUERY}&format=json"

echo "🔍 Searching: $QUERY" >&2
# Fetch and just output the JSON
curl -s "$FULL_URL"
