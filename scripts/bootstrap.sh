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


# 🐣 BIRTH CERTIFICATE: Initialize Identity
if [ ! -f "$NEXUS_WORKSPACE_DIR/IDENTITY.md" ] || grep -q "Fill this in" "$NEXUS_WORKSPACE_DIR/IDENTITY.md"; then
  echo "🐣 Initializing Nexus Agent Identity (Birth Certificate)..."
  cat >"$NEXUS_WORKSPACE_DIR/IDENTITY.md" <<EOF
# IDENTITY.md - Who Am I?

- **Name:** Alex
- **Creature:** Nexus Executive Assistant (AI)
- **Vibe:** Professional, proactive, and action-oriented
- **Emoji:** 🦞
- **Avatar:** /api/workspace/files/alex-avatar.png

---
Born: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Deployment: Marcoby-Nexus-v0.8.2
EOF

  # Create a marker for the gateway to know it's born
  touch "$OPENCLAW_STATE/.birth_certificate"
  echo "✅ Birth certificate saved to $OPENCLAW_STATE/.birth_certificate"
fi

if [ -f "./BOOTSTRAP.md" ]; then
  echo "🚀 Seeding BOOTSTRAP.md to Nexus workspace"
  cp -f "./BOOTSTRAP.md" "$NEXUS_WORKSPACE_DIR/BOOTSTRAP.md"
fi

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
    "allow": ["nexus-toolbridge"],
    "entries": {
      "whatsapp": {
        "enabled": false
      },
      "telegram": {
        "enabled": false
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
  "memory": {
    "slotPlugin": "memory-core"
  },
  "gateway": {
  "port": $OPENCLAW_GATEWAY_PORT,
  "mode": "local",
    "bind": "0.0.0.0",
    "reload": {
      "mode": "${OPENCLAW_GATEWAY_RELOAD_MODE:-hot}",
      "debounceMs": 300
    },
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
          "create_integration_from_url",
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
      "memorySearch": {
        "enabled": true
      },
      "sandbox": {
        "mode": "non-main",
        "scope": "session",
        "workspaceAccess": "${OPENCLAW_AGENTS_DEFAULTS_SANDBOX_WORKSPACEACCESS:-none}",
        "browser": {
          "enabled": true
        }
      }
    },
    "list": [
      { "id": "main", "name": "default", "workspace": "${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"},
      { "id": "nexus", "default": true, "name": "Nexus Assistant", "workspace": "$NEXUS_WORKSPACE_DIR", "sandbox": { "mode": "${OPENCLAW_NEXUS_AGENT_SANDBOX_MODE:-off}" }, "tools": { "profile": "full" } }
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
        [ -n "$OPENROUTER_API_KEY" ] && FALLBACKS_ARRAY+=("\"openrouter/anthropic/claude-sonnet-4-6\"" "\"openrouter/openai/gpt-4o\"")
        [ -n "$OPENAI_API_KEY" ] && FALLBACKS_ARRAY+=("\"openai/gpt-4o\"")
        [ -n "$ANTHROPIC_API_KEY" ] && FALLBACKS_ARRAY+=("\"anthropic/claude-sonnet-4-6\"")
        
        IFS=, ; FALLBACKS_STRING="${FALLBACKS_ARRAY[*]}" ; unset IFS
        FINAL_FALLBACKS="[$FALLBACKS_STRING]"
    fi
    
    if [ "$FINAL_FALLBACKS" == "[]" ]; then
       FINAL_FALLBACKS='["openrouter/anthropic/claude-sonnet-4-6", "openrouter/openai/gpt-4o"]'
    fi
    
    # 2. Apply Overrides
    # Default to OpenRouter Google Gemini if no primary model specified
    jq --arg model "${OPENCLAW_AGENTS_DEFAULTS_MODEL_PRIMARY:-google/gemini-3-flash-preview}" \
       --arg fallbacks "$FINAL_FALLBACKS" \
       --arg token "${OPENCLAW_GATEWAY_TOKEN:-sk-openclaw-local}" \
       --arg port "${OPENCLAW_GATEWAY_PORT:-18790}" \
       --arg bind "${OPENCLAW_GATEWAY_BIND:-0.0.0.0}" \
       --arg reload_mode "${OPENCLAW_GATEWAY_RELOAD_MODE:-hot}" \
       --arg or_key "${OPENROUTER_API_KEY:-$OPENCLAW_DEFAULT_OPENROUTER_KEY}" \
       --arg enable_gemini_cli_auth "${OPENCLAW_ENABLE_GOOGLE_GEMINI_CLI_AUTH:-0}" \
       --arg nexus_workspace "$NEXUS_WORKSPACE_DIR" \
       --arg nexus_plugin_available "$NEXUS_TOOLBRIDGE_AVAILABLE" \
       --arg sandbox_workspace_access "${OPENCLAW_AGENTS_DEFAULTS_SANDBOX_WORKSPACEACCESS:-none}" \
       --arg nexus_sandbox_mode "${OPENCLAW_NEXUS_AGENT_SANDBOX_MODE:-off}" \
       --arg nexus_sandbox_scope "${OPENCLAW_NEXUS_AGENT_SANDBOX_SCOPE:-session}" \
       --arg force_defaults "${FORCE_MODEL_DEFAULTS:-0}" \
       '
         def with_or_without_nexus_tool(base):
           if $nexus_plugin_available == "true" then
             (base + ["nexus_*", "create_integration_from_url"] | unique)
           else
             (base | map(select(. != "nexus_*" and . != "create_integration_from_url")) | unique)
           end;
         
         # 🛠️ Selective Model Enforcement (v0.8.2)
         # Soft Update: Only overwrite key fields if they are missing OR FORCE_MODEL_DEFAULTS=1
         (if (.agents.defaults.model == null or $force_defaults == "1") then
            .agents.defaults.model = { "primary": $model, "fallbacks": (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end) }
          else . end)
         | (if $enable_gemini_cli_auth != "1" and (.agents.defaults.model.primary | tostring | startswith("google-gemini-cli")) then
             .agents.defaults.model.primary = (
               if ($model | tostring | startswith("google-gemini-cli")) then
                 "openrouter/google/gemini-3-flash-preview"
               else
                 $model
               end
             )
           else . end)
         # google-antigravity models require OAuth tokens that Nexus injects via
         # `openclaw models auth paste-token`. OpenClaw gracefully skips models
         # without valid auth, so we no longer strip them from defaults here.
         # google-gemini-cli models are opt-in via the plugin flag.
         | .agents.defaults.model.fallbacks = (
             (.agents.defaults.model.fallbacks // []) |
             (if $enable_gemini_cli_auth != "1" then
                map(select((. | tostring | startswith("google-gemini-cli")) | not))
              else
                .
              end)
           )
         | (if (.env.OPENROUTER_API_KEY == null or $force_defaults == "1") then .env.OPENROUTER_API_KEY = $or_key else . end)
         | .gateway.auth.mode = "token"
         | .gateway.auth.trustedProxy.userHeader = "x-nexus-user"
         | .gateway.auth.trustedProxy.allowUsers = []
         | .gateway.mode = "local"
         | .gateway.trustedProxies = ["127.0.0.1", "::1", "172.16.0.0/12", "192.168.0.0/16", "10.0.0.0/8"]
         | .gateway.port = ($port|tonumber)
         | .gateway.bind = $bind
         | .gateway.reload.mode = $reload_mode
         | .gateway.reload.debounceMs = 300
         | .gateway.controlUi.enabled = false
         | .gateway.controlUi.allowedOrigins = ["*"]
         | .gateway.controlUi.allowInsecureAuth = true
         | .gateway.http.endpoints.chatCompletions.enabled = true
         | .gateway.http.endpoints.responses.enabled = true
         | .gateway.auth.token = $token
         | .plugins.entries."nexus-toolbridge".enabled = ($nexus_plugin_available == "true")
         | .plugins.load.paths = ["/data/.openclaw/extensions/nexus-toolbridge"]
         | .plugins.entries."google-gemini-cli-auth".enabled = ($enable_gemini_cli_auth == "1")
         # Keep Gemini CLI auth opt-in. Nexus-managed Google auth should route
         # through google-antigravity instead of forcing Code Assist credentials.
         | .plugins.allow = (
             (((.plugins.allow // []) + ["nexus-toolbridge"]) | unique)
             | (if $enable_gemini_cli_auth == "1" then
                  (. + ["google-gemini-cli-auth"] | unique)
                else
                  map(select(. != "google-gemini-cli-auth"))
                end)
           )
         | .plugins.entries.whatsapp.enabled = false
         | .plugins.entries.telegram.enabled = false
         # Memory Search: disabled — Nexus manages user memory server-side
         # (soul profiles, relationship state, RAG blocks) and injects it via
         # the system prompt. Built-in semantic recall is redundant and
         # requires a dedicated embedding provider we do not configure.
         | .agents.defaults.memorySearch.enabled = false
         # Clean up stale configs from previous v0.8.x experimental attempts
         | del(.agents.defaults.contextPruning)
         | del(.agents.defaults.streaming)
         # Image model routing: preserve user-configured image model if already set,
         # otherwise default to Gemini 3 Flash + GPT-4o fallback.
         | .agents.defaults.imageModel = (
             if .agents.defaults.imageModel.primary != null
                and .agents.defaults.imageModel.primary != ""
             then .agents.defaults.imageModel
             else {
               "primary": "google-antigravity/gemini-3-flash-preview",
               "fallbacks": [
                 "openai/gpt-4o",
                 "openrouter/google/gemini-3-flash-preview"
               ]
             }
             end
           )
         # Auth profile routing: Nexus injects per-user keys via the official
         # `openclaw models auth paste-token` CLI (profile id = provider:userId).
         # The x-nexus-user trusted proxy header (set above) tells OpenClaw
         # which user is making the request. Auth order is managed via
         # `openclaw models auth order set`. Nexus owns the OAuth refresh
         # cycle and re-injects fresh access tokens before they expire.
         | .agents.defaults.sandbox.workspaceAccess = $sandbox_workspace_access
         # Skills allowlist - allow all bundled skills
         | .skills.allowBundled = ["*"]
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
             ] | with_or_without_nexus_tool(.)
           )
         # Tiered Agent Access
         | .agents.list = (
             (.agents.list // [])
             | map(
                 if .id == "main" then
                   # Tier 1: Executive Brain - Orchestration only.
                   .default = false
                   | .tools = { "profile": "minimal", "allow": ["group:sessions", "group:messaging"] }
                   | .model = { "primary": "openai-codex/gpt-5.4", "fallbacks": ["openrouter/anthropic/claude-sonnet-4-6", "openrouter/google/gemini-3-flash-preview"] }
                 elif .id == "nexus" then
                   # Tier 2: Business Agent - full tool profile so plugin-registered nexus_* tools are included.
                   # Using profile:"full" avoids the timing issue where the nexus-toolbridge plugin
                   # registers tools lazily (per-session) AFTER the allowlist is evaluated.
                   {
                     "id": "nexus",
                     "default": true,
                     "name": "Nexus Assistant",
                     "workspace": $nexus_workspace,
                     "sandbox": (
                       if $nexus_sandbox_mode == "off" then
                         { "mode": "off" }
                       else
                         {
                           "mode": $nexus_sandbox_mode,
                           "scope": $nexus_sandbox_scope,
                           "workspaceAccess": $sandbox_workspace_access
                         }
                       end
                     ),
                     "tools": { "profile": "full" },
                     "model": { "primary": "openai-codex/gpt-5.4", "fallbacks": ["openrouter/anthropic/claude-sonnet-4-6", "openrouter/google/gemini-3-flash-preview"] }
                   }
                 else .
                 end
               )
             # Ensure nexus agent entry is always present if map did not catch it
             | if any(.[]; .id == "nexus") then . else . + [
                 {
                   "id": "nexus",
                   "default": true,
                   "name": "Nexus Assistant",
                   "workspace": $nexus_workspace,
                   "sandbox": (
                     if $nexus_sandbox_mode == "off" then
                       { "mode": "off" }
                     else
                       {
                         "mode": $nexus_sandbox_mode,
                         "scope": $nexus_sandbox_scope,
                         "workspaceAccess": $sandbox_workspace_access
                       }
                     end
                   ),
                   "tools": { "profile": "full" },
                   "model": { "primary": "openai-codex/gpt-5.4", "fallbacks": ["openrouter/anthropic/claude-sonnet-4-6", "openrouter/google/gemini-3-flash-preview"] }
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
