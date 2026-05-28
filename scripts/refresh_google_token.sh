#!/usr/bin/env bash
set -euo pipefail
# refresh_google_token.sh
# Refreshes Google OAuth2 access token using refresh_token and updates auth-profiles.json atomically.
# Usage: refresh_google_token.sh /data/.openclaw/agents/nexus/agent/auth-profiles.json /path/to/google_creds.env
#
# google_creds.env should export:
#   GOOGLE_CLIENT_ID=...
#   GOOGLE_CLIENT_SECRET=...

AUTH_PROFILES_PATH="${1:-/data/.openclaw/agents/nexus/agent/auth-profiles.json}"
GOOGLE_CREDS_ENV="${2:-/data/.openclaw/google_creds.env}"

if [ ! -f "$AUTH_PROFILES_PATH" ]; then
  echo "ERROR: auth-profiles.json not found: $AUTH_PROFILES_PATH" >&2
  exit 2
fi
if [ ! -f "$GOOGLE_CREDS_ENV" ]; then
  echo "ERROR: google_creds.env not found: $GOOGLE_CREDS_ENV" >&2
  exit 2
fi
source "$GOOGLE_CREDS_ENV"

REFRESH_TOKEN=$(jq -r '.profiles[0].refresh_token // empty' "$AUTH_PROFILES_PATH")
if [ -z "$REFRESH_TOKEN" ]; then
  echo "ERROR: No refresh_token found in $AUTH_PROFILES_PATH" >&2
  exit 3
fi

RESPONSE=$(curl -s -X POST https://oauth2.googleapis.com/token \
  -d client_id="$GOOGLE_CLIENT_ID" \
  -d client_secret="$GOOGLE_CLIENT_SECRET" \
  -d refresh_token="$REFRESH_TOKEN" \
  -d grant_type=refresh_token)

NEW_ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r .access_token)
NEW_REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r .refresh_token)
EXPIRES_IN=$(echo "$RESPONSE" | jq -r .expires_in)
if [ -z "$NEW_ACCESS_TOKEN" ] || [ "$NEW_ACCESS_TOKEN" = "null" ]; then
  echo "ERROR: Failed to refresh token: $RESPONSE" >&2
  exit 4
fi

TMP_FILE=$(mktemp)
jq --arg at "$NEW_ACCESS_TOKEN" --argjson exp $(($(date +%s)+${EXPIRES_IN:-3600})) \
  --arg rt "${NEW_REFRESH_TOKEN:-$REFRESH_TOKEN}" \
  '(.profiles[0].access_token) |= $at | (.profiles[0].refresh_token) |= $rt | (.profiles[0].expires_at) |= $exp' \
  "$AUTH_PROFILES_PATH" > "$TMP_FILE"
mv "$TMP_FILE" "$AUTH_PROFILES_PATH"
echo "Updated $AUTH_PROFILES_PATH with new access_token (expires at $(date -d @$(($(date +%s)+${EXPIRES_IN:-3600}))))"

# Signal OpenClaw to reload tokens if running (optional)
if command -v pgrep >/dev/null 2>&1; then
  OC_PID=$(pgrep -f "openclaw .*gateway" || true)
  if [ -n "$OC_PID" ]; then
    echo "Signaling OpenClaw PID $OC_PID to reload (SIGUSR1)"
    kill -USR1 "$OC_PID" || true
  fi
fi

exit 0