#!/bin/bash

URL="$1"

if [ -z "$URL" ]; then
    echo "Usage: $0 <url>"
    exit 1
fi

echo "📝 Summarizing: $URL" >&2

# Check if 'summarize' is in PATH (globally installed)
if command -v summarize >/dev/null 2>&1; then
    summarize "$URL"
else
    # Fallback to bun x
    bun x @steipete/summarize "$URL"
fi
