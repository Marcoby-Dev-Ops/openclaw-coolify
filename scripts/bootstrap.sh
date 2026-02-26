#!/usr/bin/env bash
set -e

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

# Governance: Explicit Runtime Caps
export OPENCLAW_SANDBOX_MAX_CONTAINERS="${OPENCLAW_SANDBOX_MAX_CONTAINERS:-10}"
export OPENCLAW_AGENTS_MAX_CONCURRENT="${OPENCLAW_AGENTS_MAX_CONCURRENT:-4}"
echo "💰 Economic Governor: Max Sandboxes=$OPENCLAW_SANDBOX_MAX_CONTAINERS, Max Concurrent Agents=$OPENCLAW_AGENTS_MAX_CONCURRENT"

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

You are the Nexus Executive Assistant (Alex). This workspace is your primary command center.

## Core Philosophy

- **Runtime Discipline:** You may orchestrate sandbox containers through approved OpenClaw sandbox tools only.
- **Protocol Alignment:** You MUST follow the Runtime Orchestration Protocol at all times.
- **Image Sovereignty:** You do not rely on templates or custom builds. You MAY NOT use docker build or docker push.
- **Identity & Ethics:** Your identity is authoritative via the Nexus Gateway. Your execution is constrained by OpenClaw's safety directives.

## Operational Directives

- **Bias for Action:** Proactively suggest and implement workflows within technical boundaries.
- **Execution Constraints:** You MAY NOT access host containers outside managed sandboxes.
- **Tool Discipline:** Use the specialized `nexus_*` tools for high-level orchestration; delegate intensive dev tasks to specialized sandbox agents.

## Capability Layers

### Tier 1: Orchestration
- exec: Shell access for file management, git, and sandbox management.
- sandbox: Orchestrate project-specific dev environments using image-first rules.

### Tier 2: Business Integration
- nexus_get_integration_status
- nexus_search_emails / nexus_send_email
- nexus_get_calendar_events
- nexus_generate_image

### Tier 3: Intelligence
- browser: Full web interaction
- web_search: Live internet access
- advanced_scrape: Data extraction
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
    "allow": ["whatsapp", "telegram", "nexus-toolbridge"],
    "entries": {
      "whatsapp": {
        "enabled": true
      },
      "telegram": {
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
    "controlUi": { "enabled": false },
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
      { "id": "nexus", "name": "Nexus Assistant", "workspace": "$NEXUS_WORKSPACE_DIR", "sandbox": { "mode": "off" }, "tools": { "profile": "minimal", "allow": ["nexus_*"] } }
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
    if [[ "$OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS" != \[* ]]; then
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
    # Default to OpenRouter Google Gemini if no primary model specified
    jq --arg model "${OPENCLAW_AGENTS_DEFAULTS_MODEL_PRIMARY:-google/gemini-2.0-flash}" \
       --arg fallbacks "$FINAL_FALLBACKS" \
       --arg token "${OPENCLAW_GATEWAY_TOKEN:-sk-openclaw-local}" \
       --arg port "${OPENCLAW_GATEWAY_PORT:-18790}" \
       --arg bind "${OPENCLAW_GATEWAY_BIND:-0.0.0.0}" \
       --arg or_key "${OPENROUTER_API_KEY:-$OPENCLAW_DEFAULT_OPENROUTER_KEY}" \
       --arg nexus_workspace "$NEXUS_WORKSPACE_DIR" \
       --arg nexus_plugin_available "$NEXUS_TOOLBRIDGE_AVAILABLE" \
       --arg force_defaults "${FORCE_MODEL_DEFAULTS:-0}" \
       '
         def with_or_without_nexus_tool(base):
           if $nexus_plugin_available == "true" then
             (base + ["nexus_*"] | unique)
           else
             (base | map(select(. != "nexus_*")) | unique)
           end;
         
         # 🛠️ Selective Model Enforcement (v0.8.2)
         # Soft Update: Only overwrite key fields if they are missing OR FORCE_MODEL_DEFAULTS=1
         (if (.agents.defaults.model == null or $force_defaults == "1") then
            .agents.defaults.model = { "primary": $model, "fallbacks": (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end) }
          else . end)
         | (if (.env.OPENROUTER_API_KEY == null or $force_defaults == "1") then .env.OPENROUTER_API_KEY = $or_key else . end)
         | .gateway.auth.token = $token
         | .gateway.port = ($port|tonumber)
         | .gateway.bind = $bind
         | .gateway.http.endpoints.responses.enabled = true
         | .plugins.entries."nexus-toolbridge".enabled = ($nexus_plugin_available == "true")
         | .plugins.allow = ["whatsapp", "telegram", "nexus-toolbridge"]
         | del(.plugins.entries."google-antigravity-auth")
         # Ensure the models requested in defaults are actually mapped in the models config
         | (if (.agents.defaults.model != null) then
             (.agents.defaults.model.primary as $p | .agents.defaults.models[$p] = {})
             | reduce (.agents.defaults.model.fallbacks[]?) as $fb (.; .agents.defaults.models[$fb] = {})
           else . end)
         # 3. Authority Separation & Tool Tiering (v0.8)
         # Ensure sandboxed sessions (workers) can NEVER call Nexus tools.
         | .tools.profile = "full"
         | del(.tools.alsoAllow)
         | .tools.sandbox.tools.allow = (
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
           )
         # Tiered Agent Access
         | .agents.list = (
             (.agents.list // [])
             | map(
                 if .id == "main" then
                   # Tier 1: Executive Brain - Orchestration only.
                   .tools = { "profile": "minimal", "allow": ["group:sessions", "group:messaging"] }
                 elif .id == "nexus" then
                   # Tier 2: Business Agent - nexus_* + intelligence only, no exec/sandbox.
                   {
                     "id": "nexus",
                     "name": "Nexus Assistant",
                     "workspace": $nexus_workspace,
                     "sandbox": { "mode": "off" },
                     "tools": { 
                       "profile": "minimal", 
                       "allow": with_or_without_nexus_tool(["browser", "web_search", "advanced_scrape", "group:messaging"]) 
                     }
                   }
                 else .
                 end
               )
             # Ensure nexus agent entry is always present if map did not catch it
             | if any(.[]; .id == "nexus") then . else . + [
                 {
                   "id": "nexus",
                   "name": "Nexus Assistant",
                   "workspace": $nexus_workspace,
                   "sandbox": { "mode": "off" },
                   "tools": { 
                     "profile": "minimal", 
                     "allow": with_or_without_nexus_tool(["browser", "web_search", "advanced_scrape", "group:messaging"]) 
                   }
                 }
               ] end
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
