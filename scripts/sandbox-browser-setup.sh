#!/bin/bash
set -e

# Inherit DOCKER_HOST if set, or default to socket proxy
export DOCKER_HOST="${DOCKER_HOST:-tcp://docker-proxy:2375}"

echo "🦞 Building OpenClaw Sandbox Browser Image..."

# Use playwright image for browser capabilities
BASE_IMAGE="mcr.microsoft.com/playwright:v1.41.0-jammy"
TARGET_IMAGE="openclaw-sandbox-browser:bookworm-slim"

# Check if image already exists
if docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
    echo "✅ Sandbox browser image already exists: $TARGET_IMAGE"
    exit 0
fi

echo "   Pulling $BASE_IMAGE..."
RETRY_COUNT=0
MAX_RETRIES=5
until docker pull "$BASE_IMAGE" >/dev/null 2>&1 || [ $RETRY_COUNT -eq $MAX_RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "   [attempt $RETRY_COUNT/$MAX_RETRIES] Retrying pull $BASE_IMAGE..."
    sleep 3
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Failed to pull $BASE_IMAGE. Is docker-proxy healthy?"
    exit 1
fi

echo "   Tagging as $TARGET_IMAGE..."
docker tag "$BASE_IMAGE" "$TARGET_IMAGE"

echo "✅ Sandbox browser image ready: $TARGET_IMAGE"
