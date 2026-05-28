#!/usr/bin/env bash
set -euo pipefail
# apply_openclaw_config.sh
# Atomically validate and apply an OpenClaw `openclaw.json` config to a runtime
# Usage: apply_openclaw_config.sh /path/to/new_openclaw.json [/data/.openclaw/openclaw.json]

NEW_CONFIG_PATH="$1"
TARGET_PATH="${2:-/data/.openclaw/openclaw.json}"

if [ ! -f "$NEW_CONFIG_PATH" ]; then
  echo "ERROR: input file not found: $NEW_CONFIG_PATH" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
TMP_FILE="$TMP_DIR/openclaw.json.tmp"

cp "$NEW_CONFIG_PATH" "$TMP_FILE"

# Basic JSON validity check
if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
  echo "ERROR: JSON validation failed for $NEW_CONFIG_PATH" >&2
  rm -rf "$TMP_DIR"
  exit 3
fi

# Ensure model entries include id and name
MISSING_MODEL_FIELDS=$(jq -r '
  .models.providers // {} | to_entries[]? as $p |
  ($p.value.models // [])[]? | select((.id==null) or (.name==null)) | "",$p.key' "$TMP_FILE" | sed '/^$/d' || true)

if [ -n "$MISSING_MODEL_FIELDS" ]; then
  echo "ERROR: one or more models are missing 'id' or 'name' fields:" >&2
  echo "$MISSING_MODEL_FIELDS" >&2
  rm -rf "$TMP_DIR"
  exit 4
fi

echo "Validated JSON and model fields. Preparing backup and applying atomically..."

TS="$(date +%s)"
BACKUP_DIR="/data/.openclaw/backups"
mkdir -p "$BACKUP_DIR"

if [ -f "$TARGET_PATH" ]; then
  cp "$TARGET_PATH" "$BACKUP_DIR/openclaw.json.last-good.$TS"
  echo "Backed up existing config to $BACKUP_DIR/openclaw.json.last-good.$TS"
fi

# Atomic replace
mv "$TMP_FILE" "$TARGET_PATH"
sync

echo "Config moved to $TARGET_PATH"

# Try to notify OpenClaw to reload (SIGUSR1 typical for reloads)
if command -v pgrep >/dev/null 2>&1; then
  OC_PID=$(pgrep -f "openclaw .*gateway" || true)
  if [ -n "$OC_PID" ]; then
    echo "Signaling OpenClaw PID $OC_PID to reload (SIGUSR1)"
    kill -USR1 "$OC_PID" || true
  else
    echo "No local openclaw gateway process found via pgrep; if running in Docker, send SIGUSR1 to the container or restart the gateway." >&2
  fi
fi

# Run an optional runtime probe if `openclaw` CLI is available
if command -v openclaw >/dev/null 2>&1; then
  echo "Running: openclaw models status --probe --json"
  if ! openclaw models status --probe --json >/dev/null 2>&1; then
    echo "WARNING: runtime probe failed after applying config. Consider rolling back to last-good." >&2
    exit 5
  fi
  echo "Runtime probe passed. Apply complete."
else
  echo "openclaw CLI not found locally; please run 'openclaw models status --probe --json' in the runtime to verify." >&2
fi

rm -rf "$TMP_DIR"
exit 0
