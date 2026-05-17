# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

This is the **Marcoby deployment package** for OpenClaw — an open AI agent gateway that runs on Coolify. The repo does not contain the OpenClaw runtime source; it packages the runtime (installed via `npm install -g openclaw`) with:

- A **bootstrap script** that builds `openclaw.json` from environment variables at container startup
- The **nexus-toolbridge** OpenClaw plugin that bridges Nexus tools into the OpenClaw tool catalog
- Bundled **skills** (sandbox-manager, web-utils, learning) that run as in-container scripts
- A **docker-compose** config for Coolify deployment
- A **CI/CD workflow** that builds and pushes to GHCR on every push to `main`

The container exposes the OpenClaw gateway on port `18790` and is accessed exclusively through Nexus — direct public access is disabled by design.

## Repository Layout

```
scripts/bootstrap.sh        Container entrypoint — builds openclaw.json, starts gateway
scripts/openclaw-config.jq  jq transform applied to openclaw.json on every boot
extensions/
  nexus-toolbridge/         OpenClaw plugin: bridges Nexus tools into the agent runtime
    index.ts                Main plugin code (~1200 lines)
    openclaw.plugin.json    Plugin manifest with static tool contracts
    hooks/
      auto-configure-nexus-url/   Startup hook: discovers NEXUS_API_URL
      nexus-identity-primer/      Session hook: seeds Nexus user identity
skills/
  sandbox-manager/          Skill: spawn and manage Docker sandboxes via Cloudflare tunnels
  web-utils/                Skill: web search + scraping scripts
  learning/                 Skill: study/learning utilities
searxng/                    Self-hosted search sidecar (used by web-utils)
docker-compose.ghcr.yaml    Coolify compose (pulls from GHCR)
Dockerfile                  Multi-stage build: system tools → runtimes → app deps → final
.env.example                All configurable environment variables with descriptions
AUTHORITY.md                Agent tier definitions and prime directives (enforced at runtime)
SOUL.md                     Runtime safety constraints embedded in the agent context
```

## Commands

This repo has no build step, test suite, or dev server of its own. Development work is:

**Editing TypeScript (nexus-toolbridge):**

```bash
# Type-check the plugin (uses tsconfig.json at repo root)
npx tsc --noEmit

# The plugin is not bundled locally — it runs via tsx inside the container.
# To test changes: rebuild the Docker image or volume-mount the extension into a running container.
```

**Testing a container change locally:**

```bash
docker build -t openclaw-local .
docker run --rm -p 18790:18790 --env-file .env openclaw-local
```

**CI/CD — push to GHCR:**

Pushing to `main` triggers `.github/workflows/docker-publish.yml` which builds and pushes `ghcr.io/marcoby-dev-ops/openclaw-coolify:latest`. The `OPENCLAW_VERSION` ARG is read from the `Dockerfile` unless overridden via `workflow_dispatch`.

**Sandbox reaper (host cron on mar-ubu01):**

A user-cron on the host reaps leaked sandbox containers that OpenClaw spawns per-call and does not self-clean. `scripts/monitor_sandbox.sh` and `scripts/recover_sandbox.sh` run inside the container on a 5-minute loop for in-container health checks.

## Architecture

### Container Startup Flow

1. `scripts/bootstrap.sh` runs as `CMD`.
2. It checks/waits for `docker-proxy:2375` (the Docker socket proxy sidecar).
3. If `openclaw.json` doesn't exist, it writes a seed config enabling the `nexus-toolbridge` plugin and defining two agents: `main` (general workspace) and `nexus` (Nexus-specific, default).
4. `scripts/openclaw-config.jq` is applied via `jq` to enforce env-var overrides on every boot — model routing, auth token, gateway port, sandbox config, API keys. This means **env vars always win over persisted volume state**.
5. Stale plugins (`brave`, `telegram`, `whatsapp`, etc.) are pruned from `openclaw.json` — only `nexus-toolbridge` is managed here.
6. Sandbox images are pre-pulled/built via `sandbox-setup.sh`.
7. `exec openclaw gateway run` starts the gateway on port 18790.

### Nexus Toolbridge Plugin (`extensions/nexus-toolbridge/index.ts`)

This is the main code in this repo. It is an OpenClaw plugin that:

1. **Fetches the tool catalog from Nexus** on startup and on a TTL interval (default 30s, configurable via `NEXUS_TOOL_CATALOG_TTL_MS`). Hits `GET {NEXUS_API_URL}/api/openclaw/tools/catalog` with ETAG-based caching to avoid redundant refreshes.

2. **Registers all Nexus tools with OpenClaw dynamically** — the catalog comes from Nexus so new tools appear in OpenClaw without rebuilding this container.

3. **Splits execution into two paths**:
   - **Local file tools** (`nexus_read_file`, `nexus_write_file`, `nexus_list_files`) — executed directly in the container against the per-user workspace directory (`/data/workspace/{userId}/`) for speed and to avoid round-trips.
   - **All other tools** — proxied to `POST {NEXUS_API_URL}/api/openclaw/tools/execute` with auth headers `X-OpenClaw-Api-Key`, `X-Nexus-User-Id`, and `X-Nexus-Conversation-Id`.

4. **JIT credential sync** — before tool calls, fetches per-user API keys from Nexus via `GET /api/openclaw/credentials` and sets them as environment variables in the OpenClaw process. Cache TTL is 5 minutes. This allows BYOK keys managed in Nexus to flow into OpenClaw without docker exec injection.

5. **User identity resolution** — extracts the Nexus `userId` from the OpenClaw session key (format: `nexus-user:{userId}:{conversationId}`), request context, or cached session registry. The `nexus-identity-primer` hook seeds this on session start.

### Agent Authority Tiers (`AUTHORITY.md`)

Three tiers with distinct tool access — enforced by OpenClaw's tool allowlist, not this plugin:

| Tier | Agent | Tools | Restriction |
|------|-------|-------|------------|
| 1 | main (Chief of Staff) | No exec, no sandbox | Strategic only |
| 2 | nexus (Nexus Assistant) | `nexus_*`, `browser`, `web_search` | No exec, no sandbox management |
| 3 | Worker sandboxes | `exec`, `process`, `read`, `write`, `edit` | No `nexus_*` tools |

**Prime Directives (never violate):**
- All Docker ops go through `tcp://docker-proxy:2375` — never the host socket directly.
- `docker build` and `docker push` are permanently forbidden.
- Max 10 concurrent sandbox containers; max 4 concurrent agents.

### Service Topology (docker-compose.ghcr.yaml)

```
openclaw        Port 18790 — gateway (this container)
docker-proxy    Port 2375  — tecnativa/docker-socket-proxy (guards host socket)
searxng         Port 8080  — self-hosted search (used by web-utils skill)
registry        Port 5000  — private image registry
```

All services share the `coolify` external network. `openclaw` depends on `docker-proxy` being healthy before starting.

## Key Environment Variables

| Variable | Purpose |
|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | Auth token for the gateway (`sk-openclaw-local` default — change in production) |
| `OPENCLAW_GATEWAY_PORT` | Port (default: 18790) |
| `NEXUS_API_URL` | URL of the Nexus backend API (e.g. `http://nexus:3001`) |
| `NEXUS_OPENCLAW_API_KEY` | Must match Nexus's `OPENCLAW_API_KEY` — used by toolbridge to authenticate tool calls back to Nexus |
| `OPENCLAW_AGENTS_DEFAULTS_MODEL_PRIMARY` | Primary LLM for all agents |
| `OPENCLAW_AGENTS_DEFAULTS_MODEL_FALLBACKS` | Comma-separated fallback model list |
| `OPENROUTER_API_KEY` / `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | Provider keys — injected by Nexus per-user at runtime |
| `OPENCLAW_NEXUS_AGENT_SANDBOX_MODE` | `non-main` (default) or `main` |
| `OPENCLAW_AGENTS_DEFAULTS_SANDBOX_WORKSPACEACCESS` | `none` \| `ro` \| `rw` |
| `FORCE_MODEL_DEFAULTS` | Set to `1` to overwrite the persisted model in `openclaw.json` on next boot |
| `NEXUS_TOOL_CATALOG_TTL_MS` | How often the toolbridge refreshes the Nexus tool catalog (default: 30000ms) |

Env-var changes in Coolify require a container restart to apply (values are written into `openclaw.json` only at bootstrap time).

## Important Conventions

- **`openclaw.json` is rebuilt on every boot** — do not rely on manual edits to `openclaw.json` in the volume persisting across redeploys. All configuration must be expressed as env vars that flow through `bootstrap.sh` → `openclaw-config.jq`.
- **Toolbridge is the only managed plugin** — the bootstrap strips all other plugins (`brave`, `telegram`, `whatsapp`, etc.) from `openclaw.json`. Do not add other plugins via Coolify env vars; they will be removed on next restart.
- **The toolbridge plugin (`index.ts`) is not bundled** — it runs via the OpenClaw plugin loader directly from `/app/extensions/nexus-toolbridge/`. Changes to it take effect on the next gateway restart (no build step required for the extension itself).
- **Sandbox containers must be labeled** — any container managed by the sandbox-manager skill must carry label `SANDBOX_CONTAINER=true` or `openclaw.managed=true`, or start with name `openclaw-sandbox-`. The agent will not touch unlabeled containers.
- **Workspace paths are per-user** — user workspace is at `/data/workspace/{sanitized-userId}/`. The `sanitizeWorkspaceUserId` function strips non-alphanumeric characters. Do not store files at the root `/data/workspace/` — they won't be isolated.
