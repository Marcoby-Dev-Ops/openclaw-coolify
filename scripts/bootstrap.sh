#!/usr/bin/env bash
# ------------------------------------------------------------------
# 📣 NOTE TO DEVELOPERS
# ------------------------------------------------------------------
# The Nexus backend performs OAuth for each supported provider (GitHub,
# OpenAI, Anthropic, OpenRouter, Google Gemini, …) and stores the
# resulting access token in the `oauth_tokens` table.
#
# When a user’s sandbox is started, Nexus injects those tokens into the
# container environment as:
#   OPENROUTER_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, …
#
# This bootstrap script reads those variables and writes them into
# openclaw.json.  Do NOT set these variables manually in an .env file –
# they are managed automatically by Nexus.
set -e

# ------------------------------------------------------------------
# 📂 Path Setup (resolve all paths before anything else)
# ------------------------------------------------------------------
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE}/openclaw.json}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/data/workspace}"
NEXUS_WORKSPACE_DIR="${NEXUS_WORKSPACE_DIR:-${WORKSPACE_DIR}/nexus}"
NEXUS_TOOLBRIDGE_AVAILABLE="${NEXUS_TOOLBRIDGE_AVAILABLE:-true}"

mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR" "$NEXUS_WORKSPACE_DIR"

# ------------------------------------------------------------------
# 🛡️ Docker Socket Safety & Enforcement
# ------------------------------------------------------------------
export DOCKER_HOST="tcp://docker-proxy:2375"
echo "🧱 Enforcing DOCKER_HOST=$DOCKER_HOST (Nexus Control Plane v0.8)"

WAIT_COUNT=0
MAX_WAIT=5
echo "⏳ Verifying docker-proxy is reachable..."
until nc -z docker-proxy 2375 >/dev/null 2>&1 || [ $WAIT_COUNT -eq $MAX_WAIT ]; do
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

if ! nc -z docker-proxy 2375 >/dev/null 2>&1; then
  echo "⏳ docker-proxy not reached yet. Will re-check in background (sandbox may be temporarily unavailable)."

  # Run retry in background function to keep the main flow clean
  retry_docker_proxy() {
    GRACE_SEC="${OPENCLAW_DOCKER_PROXY_GRACE_SEC:-60}"
    INTERVAL_SEC="${OPENCLAW_DOCKER_PROXY_RETRY_INTERVAL_SEC:-2}"
    deadline=$(( $(date +%s) + GRACE_SEC ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
      if nc -z docker-proxy 2375 >/dev/null 2>&1; then
        echo "✅ docker-proxy is UP (post-startup)."
        return 0
      fi
      sleep "$INTERVAL_SEC"
    done

    echo "⚠️  WARNING: docker-proxy still not reachable after ${GRACE_SEC}s. Sandbox features may fail."
  }

  retry_docker_proxy &
fi

# ------------------------------------------------------------------
# 🔄 ENFORCEMENT: Environment Overrides openclaw.json
# ------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    # Create minimal seed config — jq transform below applies all real settings
    echo "🏥 Generating initial openclaw.json..."
    cat >"$CONFIG_FILE" <<EOF
{
  "plugins": {
    "enabled": true,
    "allow": ["nexus-toolbridge"],
    "entries": {
      "nexus-toolbridge": { "enabled": true }
    }
  },
  "skills": {
    "allowBundled": ["*"],
    "install": { "nodeManager": "npm" }
  },
  "memory": { "slotPlugin": "memory-core" },
  "tools": {
    "profile": "full",
    "sandbox": {
      "tools": {
        "allow": [
          "exec", "process", "read", "write", "edit", "apply_patch", "image",
          "sessions_list", "sessions_history", "sessions_send", "sessions_spawn", "session_status",
          "create_integration_from_url", "nexus_*"
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE_DIR",
      "envelopeTimestamp": "on",
      "envelopeElapsed": "on",
      "cliBackends": {},
      "heartbeat": { "every": "1h" },
      "maxConcurrent": 4,
      "memorySearch": { "enabled": true },
      "sandbox": {
        "mode": "non-main",
        "scope": "session",
        "workspaceAccess": "${OPENCLAW_AGENTS_DEFAULTS_SANDBOX_WORKSPACEACCESS:-none}",
        "browser": { "enabled": true }
      }
    },
    "list": [
      { "id": "main", "name": "default", "workspace": "${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"},
      { "id": "nexus", "default": true, "name": "Nexus Assistant", "workspace": "$NEXUS_WORKSPACE_DIR", "sandbox": { "mode": "${OPENCLAW_NEXUS_AGENT_SANDBOX_MODE:-non-main}" }, "tools": { "profile": "full" } }
    ]
  }
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Seed openclaw.json created — applying env var overrides..."
    # Force model + auth on fresh installs regardless of FORCE_MODEL_DEFAULTS
    FORCE_MODEL_DEFAULTS=1
fi

echo "🔄 Enforcing Nexus/Marcoby configuration in openclaw.json..."

# 1. Fallback Construction
# Clean up and convert comma-list to JSON array if it isn't already JSON
if [[ "$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS" != \[* ]]; then
    # Convert "a, b, c" to ["a","b","c"]
    JSON_FALLBACKS=$(echo "$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS" | jq -Rc 'split(",") | map(sub("^\\s+"; "")) | map(sub("\\s+$"; ""))')
    FINAL_FALLBACKS="$JSON_FALLBACKS"
else
    FINAL_FALLBACKS="$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS"
fi

if [ -z "$FINAL_FALLBACKS" ] || [ "$FINAL_FALLBACKS" == "[]" ]; then
    FALLBACKS_ARRAY=()
    [ -n "$GEMINI_API_KEY" ] && FALLBACKS_ARRAY+=("\"google-antigravity/gemini-3.1-pro-preview\"" "\"google-antigravity/gemini-3-flash-preview\"" "\"google-antigravity/gemini-2.5-pro\"")
    [ -n "$OPENROUTER_API_KEY" ] && FALLBACKS_ARRAY+=("\"openrouter/google/gemini-3.1-pro\"" "\"openrouter/openai/gpt-5.5\"" "\"openrouter/anthropic/claude-opus-4.7\"")
    [ -n "$OPENAI_API_KEY" ] && FALLBACKS_ARRAY+=("\"openai/gpt-5.4\"" "\"openai/gpt-5.2\"")
    [ -n "$ANTHROPIC_API_KEY" ] && FALLBACKS_ARRAY+=("\"anthropic/claude-opus-4-6\"" "\"anthropic/claude-sonnet-4-6\"")

    IFS=, ; FALLBACKS_STRING="${FALLBACKS_ARRAY[*]}" ; unset IFS
    FINAL_FALLBACKS="[$FALLBACKS_STRING]"
fi

if [ "$FINAL_FALLBACKS" == "[]" ]; then
   FINAL_FALLBACKS='["openrouter/google/gemini-3.1-pro-preview", "openrouter/openai/gpt-5.5", "openrouter/anthropic/claude-opus-4.7"]'
fi

# 2. Apply Overrides
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEFAULT_PRIMARY="openrouter/free"
[ -n "$GEMINI_API_KEY" ] && DEFAULT_PRIMARY="google-antigravity/gemini-3-flash-preview"

jq -f "$SCRIPT_DIR/openclaw-config.jq" \
   --arg model "${OPENCLAW_AGENTS_DEFAULTS_MODEL_PRIMARY:-$DEFAULT_PRIMARY}" \
   --arg fallbacks "$FINAL_FALLBACKS" \
   --arg token "${OPENCLAW_GATEWAY_TOKEN:-sk-openclaw-local}" \
   --arg port "${OPENCLAW_GATEWAY_PORT:-18790}" \
   --arg bind "${OPENCLAW_GATEWAY_BIND:-lan}" \
   --arg reload_mode "${OPENCLAW_GATEWAY_RELOAD_MODE:-hot}" \
   --arg or_key "${OPENROUTER_API_KEY:-$OPENCLAW_DEFAULT_OPENROUTER_KEY}" \
   --arg enable_gemini_cli_auth "${OPENCLAW_ENABLE_GOOGLE_GEMINI_CLI_AUTH:-0}" \
   --arg nexus_workspace "$NEXUS_WORKSPACE_DIR" \
   --arg nexus_plugin_available "$NEXUS_TOOLBRIDGE_AVAILABLE" \
   --arg sandbox_workspace_access "${OPENCLAW_AGENTS_DEFAULTS_SANDBOX_WORKSPACEACCESS:-none}" \
   --arg nexus_sandbox_mode "${OPENCLAW_NEXUS_AGENT_SANDBOX_MODE:-non-main}" \
   --arg nexus_sandbox_scope "${OPENCLAW_NEXUS_AGENT_SANDBOX_SCOPE:-session}" \
   --arg force_defaults "${FORCE_MODEL_DEFAULTS:-0}" \
   --arg ollama_host "${OLLAMA_HOST:-}" \
   "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
# Clean up stale external plugin entries. Nexus owns plugin exposure for this package.
jq '
  ["brave","diffs","google-gemini-cli-auth","ollama","telegram","user","whatsapp"] as $stale_plugins
  | if .plugins.entries then
      .plugins.entries |= with_entries(.key as $plugin_id | select(($stale_plugins | index($plugin_id)) | not))
    else . end
  | if .plugins.allow then
      .plugins.allow |= map(. as $plugin_id | select(($stale_plugins | index($plugin_id)) | not))
    else . end
' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Provider key warnings for missing tokens
if [ -z "$OPENROUTER_API_KEY" ] && echo "$FINAL_FALLBACKS" | grep -q 'openrouter'; then
  echo "⚠️  OpenRouter API key not found – models that require OpenRouter will be unavailable."
fi
if [ -z "$GEMINI_API_KEY" ] && echo "$FINAL_FALLBACKS" | grep -q 'google/gemini'; then
  echo "⚠️  Gemini API key not found – Google Gemini 3 models will be unavailable."
fi
if [ -z "$OPENAI_API_KEY" ] && echo "$FINAL_FALLBACKS" | grep -q 'openai/gpt-5'; then
  echo "⚠️  OpenAI API key not found – GPT-5 models will be unavailable."
fi
if [ -z "$ANTHROPIC_API_KEY" ] && echo "$FINAL_FALLBACKS" | grep -q 'anthropic/claude-4'; then
  echo "⚠️  Anthropic API key not found – Claude 4 models will be unavailable."
fi

# ----------------------------
# Export state
# ----------------------------
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"

# ----------------------------
# Sandbox setup
# ----------------------------
[ -f scripts/sandbox-setup.sh ] && bash scripts/sandbox-setup.sh
[ -f scripts/sandbox-browser-setup.sh ] && bash scripts/sandbox-browser-setup.sh

# ----------------------------
# Recovery & Monitoring
# ----------------------------
if [ -f scripts/recover_sandbox.sh ]; then
  echo "🛡️  Deploying Recovery Protocols..."
  cp scripts/recover_sandbox.sh "$WORKSPACE_DIR/"
  cp scripts/monitor_sandbox.sh "$WORKSPACE_DIR/"
  chmod +x "$WORKSPACE_DIR/recover_sandbox.sh" "$WORKSPACE_DIR/monitor_sandbox.sh"
  
  # Run initial recovery
  bash "$WORKSPACE_DIR/recover_sandbox.sh"
  
  # Start background monitor
  nohup bash "$WORKSPACE_DIR/monitor_sandbox.sh" >/dev/null 2>&1 &
fi

# ----------------------------
# Run OpenClaw
# ----------------------------
ulimit -n 65535
# ----------------------------
# Banner & Access Info
# ----------------------------
echo ""
echo "📊 Deployment Info:"
echo "   - OpenClaw Version: $(openclaw --version)"
echo "   - Image Built: ${BUILD_DATE:-unknown}"
echo ""

# Try to extract existing token if not already set (e.g. from previous run)
if [ -f "$CONFIG_FILE" ]; then
    SAVED_TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || grep -o '"token": "[^"]*"' "$CONFIG_FILE" | tail -1 | cut -d'"' -f4)
    if [ -n "$SAVED_TOKEN" ]; then
        TOKEN="$SAVED_TOKEN"
    fi
fi

echo ""
echo "=================================================================="
echo "🦞 OpenClaw is ready!"
echo "=================================================================="
echo ""
echo "🔑 Gateway auth: token mode enabled"
echo ""
echo "🌍 Service URL (Internal): http://openclaw:${OPENCLAW_GATEWAY_PORT:-18790}"
echo "🔒 Direct public OpenClaw access is disabled; use the Nexus UI/API package instead."
echo ""
echo "👉 Onboarding:"
echo "   1. Access OpenClaw through Nexus."
echo "   2. To approve this machine, run inside the container:"
echo "      openclaw-approve"
echo "   3. To start the onboarding wizard:"
echo "      openclaw onboard"
echo ""
echo "=================================================================="
echo "🔧 Current ulimit is: $(ulimit -n)"
exec openclaw gateway run
