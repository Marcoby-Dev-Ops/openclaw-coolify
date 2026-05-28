#!/usr/bin/env bash
set -euo pipefail
# probe_auth_profiles.sh
# Scans OpenClaw `auth-profiles.json` for provider profiles and warns when tokens near expiry.
# Usage: probe_auth_profiles.sh [path-to-agents-root] (default /data/.openclaw/agents)

AGENTS_ROOT="${1:-/data/.openclaw/agents}"
WEBHOOK_URL="${OPENCLAW_ALERT_WEBHOOK:-}"
WARNING_DAYS=${WARNING_DAYS:-7}

if [ ! -d "$AGENTS_ROOT" ]; then
  echo "ERROR: agents root not found: $AGENTS_ROOT" >&2
  exit 2
fi

now_epoch() { date +%s; }

alerts_count=0

while IFS= read -r -d '' profile; do
  echo "Inspecting $profile"
  mapfile -t timestamps < <(jq -r '
    [ .profiles // {}, .[]? ] | .. | objects | to_entries[]? | select(.key | test("expires_at|expiry|access_token_expires|refresh_expires"; "i")) | .value
  ' "$profile" 2>/dev/null || true)

  if [ ${#timestamps[@]} -eq 0 ]; then
    mapfile -t timestamps < <(jq -r '.. | numbers | select(. > 1000000000) | tostring' "$profile" 2>/dev/null || true)
  fi

  for ts in "${timestamps[@]:-}"; do
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      exp_epoch="$ts"
    else
      exp_epoch=$(date -d "$ts" +%s 2>/dev/null || true) || true
    fi
    if [ -z "${exp_epoch:-}" ]; then
      continue
    fi
    now=$(now_epoch)
    secs_left=$((exp_epoch - now))
    days_left=$((secs_left / 86400))
    if [ $days_left -lt 0 ]; then
      echo "EXPIRED: $profile -> expires_at $ts ($days_left days ago)"
      alerts_count=$((alerts_count+1))
    elif [ $days_left -lt $WARNING_DAYS ]; then
      echo "EXPIRING_SOON: $profile -> expires_at $ts ($days_left days left)"
      alerts_count=$((alerts_count+1))
    fi
  done
done < <(find "$AGENTS_ROOT" -maxdepth 3 -type f -name 'auth-profiles.json' -print0)

if [ $alerts_count -eq 0 ]; then
  echo "OK: no expiring tokens found in $AGENTS_ROOT"
  exit 0
fi

if [ -n "$WEBHOOK_URL" ]; then
  # Send a simple text alert (avoid complex JSON array construction here)
  curl -fsS -X POST -H 'Content-Type: text/plain' --data "OpenClaw auth-profiles alerts: $alerts_count items" "$WEBHOOK_URL" || true
fi

exit 1
