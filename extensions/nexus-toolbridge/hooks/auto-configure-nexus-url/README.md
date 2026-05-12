# OpenClaw Auto-Configuration for Nexus Integration

## Overview

When deploying OpenClaw via Nexus on Coolify, the `auto-configure-nexus-url` hook automatically discovers and configures the `NEXUS_API_URL` environment variable. This enables the nexus-toolbridge plugin to connect to Nexus at runtime and fetch credentials for AI providers.

## How It Works

1. **Hook Trigger**: The `auto-configure-nexus-url` hook runs on OpenClaw container startup (triggered by `system:startup` event)

2. **Discovery Process**: The hook looks for Nexus URL in this order:
   - `NEXUS_API_URL` env var (if it starts with `http`)
   - `NEXUS_FRONTEND_URL` env var (derives `/api` suffix automatically)
   - Coolify container metadata (future support)

3. **Configuration Update**: Once discovered, the URL is written to `/data/.openclaw/openclaw.json` if not already set

4. **Toolbridge Integration**: The nexus-toolbridge plugin can now reach Nexus to:
   - Fetch credentials for configured AI providers (OpenRouter, Anthropic, Gemini, etc.)
   - Sync user identity context
   - Provide access to Nexus tools in OpenClaw

## Deployment Setup

When deploying OpenClaw through Nexus/Coolify, ensure **at least one** of these environment variables is set on the OpenClaw service:

### Option 1: Direct API URL (Recommended)
```bash
NEXUS_API_URL=https://marcoby.nexus.marcoby.com/api
```

### Option 2: Frontend URL (Auto-derives /api)
```bash
NEXUS_FRONTEND_URL=https://marcoby.nexus.marcoby.com
```

## Configuration Files

### Hook Definition
- **Location**: `/data/.openclaw/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/HOOK.md`
- **Handler**: `handler.ts`
- **Events**: Triggered on `system:startup` and `system:initialize`

### Hook Handler
The handler performs:
```typescript
// 1. Discover Nexus URL from environment
const nexusApiUrl = discoverNexusApiUrl();

// 2. Update openclaw.json with discovered URL
if (nexusApiUrl) {
  updateOpenClawConfig(nexusApiUrl);
  logger.info('Nexus URL configured:', nexusApiUrl);
}

// 3. Log available endpoints for debugging
logAvailableEndpoints(nexusApiUrl);
```

### Main Configuration File
- **Location**: `/data/.openclaw/openclaw.json`
- **Updated by**: `auto-configure-nexus-url` hook on startup
- **Key field**: `env.NEXUS_API_URL` (populated automatically if env var is set)

## Troubleshooting

### Issue: NEXUS_API_URL remains empty after deployment
**Solution**: 
1. Check that `NEXUS_FRONTEND_URL` or `NEXUS_API_URL` is set in the OpenClaw service environment
2. Verify the value is correct (must start with `http`)
3. Restart the OpenClaw container to trigger the hook

### Issue: Toolbridge cannot reach Nexus
**Solution**:
1. Verify `NEXUS_API_URL` is set: `cat /data/.openclaw/openclaw.json | grep NEXUS_API_URL`
2. Test connectivity: `curl https://marcoby.nexus.marcoby.com/api/health`
3. Check container logs: `docker logs <container-id>` for errors from auto-config hook

### Issue: Credentials still not available to toolbridge
**Solution**:
1. Verify the hook ran: Look for "Nexus URL configured" message in logs
2. Check that user has AI provider keys stored in Nexus at `/settings` → Integrations & AI Providers
3. Verify toolbridge credentials cache is fresh: Restart OpenClaw to clear cache

## Integration with Nexus Deployment

When Nexus is deployed via Coolify and manages OpenClaw:

1. **Deployment Script** (Nexus): Sets `NEXUS_FRONTEND_URL` on OpenClaw service
2. **Auto-Config Hook** (OpenClaw): Discovers URL and updates openclaw.json
3. **Toolbridge** (OpenClaw): Uses configured URL to fetch credentials on user session start
4. **Credential Fetch** (OpenClaw → Nexus): Calls `POST /api/openclaw/credentials` with user context

## Testing the Setup

After deploying with auto-configuration:

```bash
# 1. Verify environment variable is set
docker exec <container-id> env | grep NEXUS

# 2. Check openclaw.json has the URL
docker exec <container-id> cat /data/.openclaw/openclaw.json | jq '.env.NEXUS_API_URL'

# 3. Check hook ran successfully
docker logs <container-id> | grep "auto-configure-nexus-url"

# 4. Test toolbridge can reach Nexus
docker exec <container-id> curl https://marcoby.nexus.marcoby.com/api/health
```

## Related Files

- Hook: [handler.ts](./handler.ts)
- Nexus Toolbridge: `/data/.openclaw/extensions/nexus-toolbridge/index.ts`
- Coolify Client: `Nexus/apps/server/src/services/coolifyClient.ts`
- Config Functions: [configureOpenClawNexusIntegration](./configureOpenClawNexusIntegration)
