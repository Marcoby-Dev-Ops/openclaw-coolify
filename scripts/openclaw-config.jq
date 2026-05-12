def with_or_without_nexus_tool(base):
  if $nexus_plugin_available == "true" then
    (base + ["nexus_*", "create_integration_from_url"] | unique)
  else
    (base | map(select(. != "nexus_*" and . != "create_integration_from_url")) | unique)
  end;

def unmanaged_plugin_ids:
  [
    "brave",
    "diffs",
    "google-gemini-cli-auth",
    "ollama",
    "telegram",
    "user",
    "whatsapp"
  ];

def prune_unmanaged_plugins:
  .plugins.entries = (
    (.plugins.entries // {})
    | with_entries(.key as $plugin_id | select((unmanaged_plugin_ids | index($plugin_id)) | not))
  )
  | .plugins.allow = (
    (.plugins.allow // [])
    | map(. as $plugin_id | select((unmanaged_plugin_ids | index($plugin_id)) | not))
    | unique
  );

# Selective Model Enforcement (v0.8.3)
# Soft Update: Only overwrite primary if missing OR FORCE_MODEL_DEFAULTS=1.
# Fallbacks are ALWAYS enforced so stale volume configs are cleaned up on restart.
(if (.agents.defaults.model == null or $force_defaults == "1") then
   .agents.defaults.model = { "primary": $model, "fallbacks": (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end) }
 else
   .agents.defaults.model.fallbacks = (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end)
 end)
| (if $enable_gemini_cli_auth != "1" and (.agents.defaults.model.primary | tostring | startswith("google-gemini-cli")) then
     .agents.defaults.model.primary = (
       if ($model | tostring | startswith("google-gemini-cli")) then
         "openrouter/google/gemini-3-flash-preview"
       else
         $model
       end
     )
   else . end)
| .agents.defaults.model.fallbacks = (
    (.agents.defaults.model.fallbacks // []) |
    (if $enable_gemini_cli_auth != "1" then
       map(select((. | tostring | startswith("google-gemini-cli")) | not))
     else
       .
     end) |
    map(select((. | tostring | startswith("openai-codex")) | not))
  )
| (if (.env.OPENROUTER_API_KEY == null or $force_defaults == "1") then .env.OPENROUTER_API_KEY = $or_key else . end)
| .gateway.auth = {
    "mode": "token",
    "token": $token
  }
| .gateway.mode = "local"
| .gateway.trustedProxies = ["172.16.0.0/12", "192.168.0.0/16", "10.0.0.0/8", "127.0.0.1", "::1"]
| .gateway.port = ($port|tonumber)
| .gateway.bind = $bind
| .gateway.reload.mode = $reload_mode
| .gateway.reload.debounceMs = 300
| .gateway.controlUi.enabled = false
| .gateway.controlUi.allowedOrigins = ["*"]
| .gateway.controlUi.allowInsecureAuth = true
| .gateway.http.endpoints.chatCompletions.enabled = true
| .gateway.http.endpoints.responses.enabled = true
| prune_unmanaged_plugins
| .plugins.entries."nexus-toolbridge".enabled = ($nexus_plugin_available == "true")
| .plugins.load.paths = ["/data/.openclaw/extensions/nexus-toolbridge"]
| .plugins.allow |= (((. // []) + ["nexus-toolbridge"]) | unique)
| (if ($ollama_host | length) > 0 then .env.OLLAMA_HOST = $ollama_host else . end)
| (if ($ollama_host | length) > 0 then
     .models.providers.ollama = {
       "baseUrl": $ollama_host,
       "models": [
         {"id": "llama3.2", "name": "llama3.2"},
         {"id": "qwen2.5:3b", "name": "qwen2.5:3b"}
       ]
     }
   else . end)
| .agents.defaults.memorySearch.enabled = false
| .agents.defaults.compaction = {
    "mode": "safeguard",
    "reserveTokensFloor": 24000,
    "memoryFlush": {
      "enabled": true,
      "softThresholdTokens": 6000
    }
  }
| del(.agents.defaults.contextPruning)
| del(.agents.defaults.streaming)
| .agents.defaults.timeoutSeconds = 300
| .agents.defaults.imageModel = (
    if (.agents.defaults.imageModel.primary != null and .agents.defaults.imageModel.primary != ""
        and (.agents.defaults.imageModel.primary | tostring | startswith("google-antigravity") | not)) then
      .agents.defaults.imageModel
    else
      { "primary": "", "fallbacks": [] }
    end
  )
| .agents.defaults.sandbox.workspaceAccess = $sandbox_workspace_access
| .skills.allowBundled = ["*"]
| (if (.agents.defaults.model != null) then
    (.agents.defaults.model.primary as $p | .agents.defaults.models[$p] = {})
    | reduce (.agents.defaults.model.fallbacks[]?) as $fb (.; .agents.defaults.models[$fb] = {})
  else . end)
| reduce (
    [
      "openrouter/openai/gpt-oss-120b:free",
      "openrouter/google/gemma-4-31b-it:free",
      "openrouter/minimax/minimax-m2.5:free",
      "openrouter/z-ai/glm-4.5-air:free"
    ] | .[]) as $fm (.; .agents.defaults.models[$fm] = (.agents.defaults.models[$fm] // {}))
| reduce (
    [
      "anthropic/claude-haiku-4-5",
      "anthropic/claude-sonnet-4-6",
      "anthropic/claude-opus-4-6",
      "openai/gpt-4o",
      "openai/gpt-5.2",
      "openai/gpt-5.4",
      "openai-codex/gpt-5.1",
      "openai-codex/gpt-5.2",
      "openai-codex/gpt-5.4",
      "github-copilot/gpt-4o",
      "github-copilot/gpt-5",
      "github-copilot/gpt-5-mini",
      "github-copilot/claude-sonnet-4.6",
      "google-antigravity/gemini-3-flash",
      "google-antigravity/gemini-3-flash-preview",
      "google-antigravity/gemini-3.1-pro",
      "google-antigravity/gemini-3.1-pro-low",
      "google-antigravity/claude-sonnet-4-6"
    ] | .[]) as $pm (.; .agents.defaults.models[$pm] = (.agents.defaults.models[$pm] // {}))
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
| .agents.list = (
    (.agents.list // [])
    | map(
        if .id == "main" then
          .default = false
          | .tools = { "profile": "minimal", "allow": ["group:sessions", "group:messaging"] }
          | .model = { "primary": "openrouter/free", "fallbacks": [] }
        elif .id == "nexus" then
          {
            "id": "nexus",
            "default": true,
            "name": "Nexus Assistant",
            "workspace": $nexus_workspace,
            "model": {
              "primary": $model,
              "fallbacks": (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end)
            },
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
            "tools": { "profile": "full" }
          }
        else .
        end
      )
    | if any(.[]; .id == "nexus") then . else . + [
        {
          "id": "nexus",
          "default": true,
          "name": "Nexus Assistant",
          "workspace": $nexus_workspace,
          "model": {
            "primary": $model,
            "fallbacks": (if ($fallbacks | fromjson?) then ($fallbacks | fromjson) else [] end)
          },
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
          "tools": { "profile": "full" }
        }
      ] end
  )
