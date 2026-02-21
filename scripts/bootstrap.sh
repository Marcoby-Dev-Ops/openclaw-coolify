#!/usr/bin/env bash
set -e

# ------------------------------------------------------------------
# 🛡️ Quick Sanity Check for Docker Proxy
# Note: Docker Compose ensures the proxy is healthy before starting,
#       so this is just a quick verification, not a long wait.
# ------------------------------------------------------------------
WAIT_COUNT=0
MAX_WAIT=5
echo "⏳ Verifying docker-proxy is reachable..."
until nc -z docker-proxy 2375 >/dev/null 2>&1 || [ $WAIT_COUNT -eq $MAX_WAIT ]; do
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

if ! nc -z docker-proxy 2375 >/dev/null 2>&1; then
  echo "⏳ docker-proxy not reached yet. Will re-check in background (sandbox may be temporarily unavailable)."

  # Defer warning so we don't spam on cold-start races.
  # If docker-proxy becomes reachable shortly after startup, we'll log success instead.
  (
    GRACE_SEC="${OPENCLAW_DOCKER_PROXY_GRACE_SEC:-60}"
    INTERVAL_SEC="${OPENCLAW_DOCKER_PROXY_RETRY_INTERVAL_SEC:-2}"
    deadline=$(( $(date +%s) + GRACE_SEC ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
      if nc -z docker-proxy 2375 >/dev/null 2>&1; then
        echo "✅ docker-proxy is UP (post-startup)."
        exit 0
      fi
      sleep "$INTERVAL_SEC"
    done

    echo "⚠️  WARNING: docker-proxy still not reachable after ${GRACE_SEC}s. Sandbox features may fail."
  ) &
else
  echo "✅ docker-proxy is UP."
fi

# Ensure the default OpenRouter key is available if provided
if [ -z "$OPENROUTER_API_KEY" ] && [ -n "$OPENCLAW_DEFAULT_OPENROUTER_KEY" ]; then
  export OPENROUTER_API_KEY="$OPENCLAW_DEFAULT_OPENROUTER_KEY"
  echo "✅ Using default system OpenRouter key for zero-config onboarding."
fi

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
NEXUS_WORKSPACE_DIR="$OPENCLAW_STATE/workspace-nexus"

mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR" "$NEXUS_WORKSPACE_DIR"
chmod 700 "$OPENCLAW_STATE"

mkdir -p "$OPENCLAW_STATE/credentials"
mkdir -p "$OPENCLAW_STATE/agents/main/sessions"
chmod 700 "$OPENCLAW_STATE/credentials"

# Map data dirs to home for tool compatibility
for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do
    if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then
        ln -sf "/data/$dir" "/root/$dir"
    fi
done

# ------------------------------------------------------------------
# 🔌 MARCOBY LOGIC: Seed Workspace Extensions (Plugins)
# ------------------------------------------------------------------
# OpenClaw scans ~/.openclaw/extensions/* for global plugins.
# We force-sync our Nexus tool bridge so Nexus integration tools are always available
# across all sessions (including /tools/invoke).
EXTENSIONS_DIR="$WORKSPACE_DIR/.openclaw/extensions"
mkdir -p "$EXTENSIONS_DIR"
GLOBAL_EXTENSIONS_DIR="$OPENCLAW_STATE/extensions"
mkdir -p "$GLOBAL_EXTENSIONS_DIR"
NEXUS_TOOLBRIDGE_AVAILABLE=false

if [ -d "/app/extensions/nexus-toolbridge" ]; then
  echo "🔌 Syncing nexus-toolbridge plugin to global extensions..."
  rm -rf "$GLOBAL_EXTENSIONS_DIR/nexus-toolbridge"
  cp -a "/app/extensions/nexus-toolbridge" "$GLOBAL_EXTENSIONS_DIR/nexus-toolbridge"
  NEXUS_TOOLBRIDGE_AVAILABLE=true

  # Clean up old workspace copy (avoids "duplicate plugin id" warnings).
  rm -rf "$EXTENSIONS_DIR/nexus-toolbridge" || true
else
  echo "⚠️  nexus-toolbridge plugin not found at /app/extensions/nexus-toolbridge; Nexus tools will be disabled."
fi

# ------------------------------------------------------------------
# 🧠 MARCOBY LOGIC: Seed Agent Workspaces
# ------------------------------------------------------------------
seed_agent() {
  local id="$1"
  local name="$2"
  local dir="/data/openclaw-$id"

  if [ "$id" = "main" ]; then
    dir="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
  fi

  mkdir -p "$dir"

  # ✅ MAIN agent ALWAYS gets ORIGINAL repo SOUL.md and BOOTSTRAP.md
  # We force overwrite for the main agent to ensure updates propogate
  if [ "$id" = "main" ]; then
    if [ -f "./SOUL.md" ]; then
      echo "✨ Syncing SOUL.md to $dir (Marcoby Force-Sync)"
      cp -f "./SOUL.md" "$dir/SOUL.md"
    fi
    if [ -f "./BOOTSTRAP.md" ]; then
      echo "🚀 Syncing BOOTSTRAP.md to $dir"
      cp -f "./BOOTSTRAP.md" "$dir/BOOTSTRAP.md"
    fi
    return 0
  fi

  # 🔒 For other agents: NEVER overwrite existing SOUL.md
  if [ -f "$dir/SOUL.md" ]; then
    echo "🧠 SOUL.md already exists for $id — skipping"
    return 0
  fi

  # Fallback for other agents
  cat >"$dir/SOUL.md" <<EOF
# SOUL.md - $name
You are OpenClaw, a helpful and premium AI assistant.
EOF
}

seed_agent "main" "OpenClaw"

# Seed a minimal workspace for the Nexus-focused agent. Keep this deterministic so
# Nexus tool workflows are reliable even if the main workspace evolves.
echo "🧠 Seeding Nexus agent workspace at $NEXUS_WORKSPACE_DIR..."
cat >"$NEXUS_WORKSPACE_DIR/SOUL.md" <<'EOF'
# SOUL.md - Nexus Operational Protocols

This workspace is for the Nexus Executive Assistant. Use the following protocols for all runtime operations.

## Core Philosophy

- **Bias for Action:** Don't just answer questions; propose concrete steps and execute them when authorized.
- **Business Context:** Always frame your responses in the context of the user's business goals (growth, efficiency, clarity).
- **Transparency:** Be clear about what you can do (tools) and what you know (context).
- **Evidence & Citations:** Always cite sources, news articles, and git commits.
- **Proactive Behaviors:** When a user mentions a new project, offer to create a workspace. Suggest high-value workflows. For complex tasks, break them down into a plan first.

- Use your REAL execution capabilities proactively. Take action, don't just suggest.
- Be concise and operational.
- Never claim you lack access or cannot perform an action. Use your tools.
- Never claim an integration is connected/expired unless you just verified it using a Nexus tool.

## Available Tools

You have access to a full suite of tools. USE THEM:

### Core Tools (always available)
- exec: Run shell commands (git clone, npm install, scripts, system operations)
- read: Read files from the workspace
- write: Create or overwrite files
- edit: Make targeted edits to existing files
- apply_patch: Apply structured multi-file edits
- browser: Browse web pages and extract content
- sessions_list / sessions_history / sessions_send / sessions_spawn: Session management

### Nexus Integration Tools
When the user asks about inbox/email/OAuth/integrations, use these:
- nexus_get_integration_status
- nexus_resolve_email_provider
- nexus_start_email_connection
- nexus_test_integration_connection
- nexus_search_emails
- nexus_send_email
- nexus_get_calendar_events
- nexus_disconnect_integration
- nexus_connect_imap (only if OAuth is unavailable)

### Nexus Workspace & Utilities
- nexus_list_files
- nexus_read_file
- nexus_write_file
- nexus_generate_image
- create_integration_from_url

### Skills (when available)
- web_search: Search the live internet for current information
- advanced_scrape: Extract data from specific URLs
- create_skill: Generate new automated capabilities
- list_skills / search_skills / install_skill: Manage skills

## Tool Disclosure (Required)

When you call any Nexus tool, place tool disclosure at the END of your response:

1. Write your full answer first.
2. At the bottom, add: TOOL_USED <toolName>
3. Follow with a 1-3 sentence summary of what the tool returned.
EOF

cat >"$NEXUS_WORKSPACE_DIR/AGENTS.md" <<'EOF'
# AGENTS.md - Nexus Workspace

This workspace is intentionally minimal.

Rules:
- Do not read or write workspace memory files unless explicitly asked.
- Treat Nexus backend data as the source of truth.
- For integration workflows, run the relevant nexus_* tool immediately.
EOF

# ----------------------------
# Generate Config with Prime Directive
# ----------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "🏥 Generating openclaw.json with Prime Directive..."
  TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
  cat >"$CONFIG_FILE" <<EOF
{
"commands": {
    "native": true,
    "nativeSkills": true,
    "text": true,
    "bash": true,
    "config": true,
    "debug": true,
    "restart": true,
    "useAccessGroups": true
  },
  "plugins": {
    "enabled": true,
    "entries": {
      "whatsapp": {
        "enabled": true
      },
      "telegram": {
        "enabled": true
      },
      "google-antigravity-auth": {
        "enabled": true
      },
      "nexus-toolbridge": {
        "enabled": true
      }
    }
  },
  "skills": {
    "allowBundled": [
      "*"
    ],
    "install": {
      "nodeManager": "npm"
    }
  },
  "gateway": {
  "port": $OPENCLAW_GATEWAY_PORT,
  "mode": "local",
    "bind": "0.0.0.0",
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false
    },
    "trustedProxies": [
      "*"
    ],
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    },
    "auth": { "mode": "token", "token": "$TOKEN" },
    "http": {
      "endpoints": {
        "responses": { "enabled": true }
      }
    }
  },
  "tools": {
    "profile": "full",
    "sandbox": {
      "tools": {
        "allow": [
          "exec",
          "process",
          "read",
          "write",
          "edit",
          "apply_patch",
          "image",
          "sessions_list",
          "sessions_history",
          "sessions_send",
          "sessions_spawn",
          "session_status",
          "nexus_*"
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
      "heartbeat": {
        "every": "1h"
      },
      "maxConcurrent": 4,
      "sandbox": {
        "mode": "non-main",
        "scope": "session",
        "browser": {
          "enabled": true
        }
      }
    },
    "list": [
      { "id": "main","default": true, "name": "default",  "workspace": "${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"},
      { "id": "nexus", "name": "Nexus Assistant", "workspace": "$NEXUS_WORKSPACE_DIR", "sandbox": { "mode": "off" }, "tools": { "profile": "full", "alsoAllow": ["nexus_*"] } }
    ]
  }
}
EOF
chmod 600 "$CONFIG_FILE"
fi

# ------------------------------------------------------------------
# 🔄 ENFORCEMENT: Environment Overrides openclaw.json
# ------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    echo "🔄 Enforcing Nexus/Marcoby configuration in openclaw.json..."
    
    # 1. Fallback Construction
    # Clean up and convert comma-list to JSON array if it isn't already JSON
    if [[ "$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS" != [* ]]; then
        # Convert "a, b, c" to ["a","b","c"]
        JSON_FALLBACKS=$(echo "$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS" | jq -Rc 'split(",") | map(sub("^\\s+"; "")) | map(sub("\\s+$"; ""))')
        FINAL_FALLBACKS="$JSON_FALLBACKS"
    else
        FINAL_FALLBACKS="$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS"
    fi

    if [ -z "$FINAL_FALLBACKS" ] || [ "$FINAL_FALLBACKS" == "[]" ]; then
        FALLBACKS_ARRAY=()
        [ -n "$OPENROUTER_API_KEY" ] && FALLBACKS_ARRAY+=("\"openrouter/anthropic/claude-3.5-sonnet\"" "\"openrouter/openai/gpt-4o-mini\"")
        [ -n "$OPENAI_API_KEY" ] && FALLBACKS_ARRAY+=("\"openai/gpt-4o-mini\"")
        [ -n "$ANTHROPIC_API_KEY" ] && FALLBACKS_ARRAY+=("\"anthropic/claude-3-5-sonnet-20241022\"")
        
        IFS=, ; FALLBACKS_STRING="${FALLBACKS_ARRAY[*]}" ; unset IFS
        FINAL_FALLBACKS="[$FALLBACKS_STRING]"
    fi
    
    if [ "$FINAL_FALLBACKS" == "[]" ]; then
       FINAL_FALLBACKS='["openrouter/anthropic/claude-3.5-sonnet", "openrouter/openai/gpt-4o-mini"]'
    fi
    
    # 2. Apply Overrides
    # Default to OpenRouter DeepSeek V3.2 if no primary model specified
    jq --arg model "${OPENCLAW_AGENTS_DEFAULTS_MODEL_PRIMARY:-openrouter/deepseek/deepseek-v3.2}" \
       --arg fallbacks "$FINAL_FALLBACKS" \
       --arg token "${OPENCLAW_GATEWAY_TOKEN:-sk-openclaw-local}" \
       --arg port "${OPENCLAW_GATEWAY_PORT:-18790}" \
       --arg bind "${OPENCLAW_GATEWAY_BIND:-0.0.0.0}" \
       --arg or_key "${OPENROUTER_API_KEY:-$OPENCLAW_DEFAULT_OPENROUTER_KEY}" \
       --arg nexus_workspace "$NEXUS_WORKSPACE_DIR" \
       --arg nexus_plugin_available "$NEXUS_TOOLBRIDGE_AVAILABLE" \
       '
         def with_or_without_nexus_tool(base):
           if $nexus_plugin_available == "true" then
             (base + ["nexus_*"] | unique)
           else
             (base | map(select(. != "nexus_*")) | unique)
           end;
         .agents.defaults.model = { "primary": $model, "fallbacks": ($fallbacks | fromjson? // [$fallbacks]) }
         | .gateway.auth.token = $token
         | .gateway.port = ($port|tonumber)
         | .gateway.bind = $bind
         | .gateway.http.endpoints.chatCompletions.enabled = true
         | .env.OPENROUTER_API_KEY = $or_key
         | .plugins.entries."nexus-toolbridge".enabled = ($nexus_plugin_available == "true")
         | .agents.defaults.models[$model] = {}
         | reduce ($fallbacks | fromjson? // [$fallbacks])[] as $fb (.; .agents.defaults.models[$fb] = {})
         # Ensure sandboxed sessions can call Nexus tools (non-main agents run in sandbox by default).
         | .tools.profile = "full"
         | del(.tools.alsoAllow)
         | .tools.sandbox.tools.allow = (
             with_or_without_nexus_tool(
               if (.tools.sandbox.tools.allow | type) == "array" then
                 .tools.sandbox.tools.allow
               else
                 [
                   "exec",
                   "process",
                   "read",
                   "write",
                   "edit",
                   "apply_patch",
                   "image",
                   "sessions_list",
                   "sessions_history",
                   "sessions_send",
                   "sessions_spawn",
                   "session_status"
                 ]
               end
             )
           )
         # Ensure a dedicated Nexus agent exists with full tools + Nexus bridged tools.
         | .agents.list = (
             (.agents.list // [])
             | map(select(.id != "nexus"))
             + [
                 if $nexus_plugin_available == "true" then
                   {
                     "id": "nexus",
                     "name": "Nexus Assistant",
                     "workspace": $nexus_workspace,
                     "sandbox": { "mode": "off" },
                     "tools": { "profile": "full", "alsoAllow": ["nexus_*"] }
                   }
                 else
                   {
                     "id": "nexus",
                     "name": "Nexus Assistant",
                     "workspace": $nexus_workspace,
                     "sandbox": { "mode": "off" },
                     "tools": { "profile": "full" }
                   }
                 end
               ]
           )
       ' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
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
echo "🔑 Access Token: $TOKEN"
echo ""
echo "🌍 Service URL (Local): http://localhost:${OPENCLAW_GATEWAY_PORT:-18790}?token=$TOKEN"
if [ -n "$SERVICE_FQDN_OPENCLAW" ]; then
    echo "☁️  Service URL (Public): https://${SERVICE_FQDN_OPENCLAW}?token=$TOKEN"
    echo "    (Wait for cloud tunnel to propagate if just started)"
fi
echo ""
echo "👉 Onboarding:"
echo "   1. Access the UI using the link above."
echo "   2. To approve this machine, run inside the container:"
echo "      openclaw-approve"
echo "   3. To start the onboarding wizard:"
echo "      openclaw onboard"
echo ""
echo "=================================================================="
echo "🔧 Current ulimit is: $(ulimit -n)"
exec openclaw gateway run
