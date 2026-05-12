# Deploying OpenClaw Auto-Configuration - User Guide

## Overview

You've been experiencing Nexus conversation failures due to `NEXUS_API_URL` not being configured in OpenClaw. The new auto-configuration system automatically discovers and sets this URL on container startup.

## Quick Start - 3 Steps

### Step 1: Set Environment Variable in Coolify

In your Coolify deployment for OpenClaw (`bogsks0oww0cwscwg0ssogcs`), add one of these environment variables:

**Option A: Frontend URL (Recommended)**
```
NEXUS_FRONTEND_URL=https://marcoby.nexus.marcoby.com
```

**Option B: Direct API URL**
```
NEXUS_API_URL=https://marcoby.nexus.marcoby.com/api
```

**Steps in Coolify UI:**
1. Open your OpenClaw service: `bogsks0oww0cwscwg0ssogcs`
2. Go to Environment → Environment Variables
3. Add the environment variable above
4. Save

### Step 2: Restart OpenClaw Container

**Via Docker (Quick):**
```bash
ssh mar-ubu01 'docker restart a0af2813b9dd'
```

**Via Coolify UI:**
1. Go to your OpenClaw service
2. Click "Deploy" or "Restart"
3. Monitor logs to see auto-config hook run

### Step 3: Verify Configuration

After container restarts, verify the auto-config hook ran:

```bash
# Check logs for auto-config success
ssh mar-ubu01 'docker logs a0af2813b9dd | grep -i "auto-configure\|nexus url"'

# Check that NEXUS_API_URL is now set
ssh mar-ubu01 'docker exec a0af2813b9dd cat /data/.openclaw/openclaw.json | jq ".env.NEXUS_API_URL"'

# Should output: "https://marcoby.nexus.marcoby.com/api"
```

## What's Changed

### 1. New Auto-Config Hook
- **Location**: `openclaw-coolify/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/`
- **Trigger**: Runs on container startup (`system:startup` event)
- **Function**: Discovers and configures `NEXUS_API_URL` automatically

### 2. Updated Coolify Client
- **File**: `Nexus/apps/server/src/services/coolifyClient.ts`
- **New Function**: `configureOpenClawNexusIntegration()`
- **Purpose**: Allows Nexus to set OpenClaw environment variables during deployment

### 3. Documentation
- **README**: `openclaw-coolify/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/README.md`

## How It Works

```
1. You set NEXUS_FRONTEND_URL=https://marcoby.nexus.marcoby.com in Coolify
2. Coolify passes it to OpenClaw container at startup
3. auto-configure-nexus-url hook runs on system:startup
4. Hook discovers URL and writes to /data/.openclaw/openclaw.json
5. nexus-toolbridge can now reach https://marcoby.nexus.marcoby.com/api
6. toolbridge fetches your AI provider credentials from Nexus DB
7. Conversations use your OpenRouter credits instead of failing
```

## Troubleshooting

### Problem: NEXUS_API_URL still empty after restart
**Solution:**
1. Confirm `NEXUS_FRONTEND_URL` or `NEXUS_API_URL` is set in Coolify environment
2. Wait 5 seconds for container to fully start
3. Check logs: `docker logs a0af2813b9dd | tail -20`
4. Manually set if needed (see "Manual Configuration" below)

### Problem: Auto-config hook didn't run
**Solution:**
1. Check container has `/data/.openclaw/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/` directory
2. Verify handler.ts and HOOK.md exist
3. Check container logs for errors: `docker logs a0af2813b9dd | grep -i error`

### Problem: Toolbridge still can't reach Nexus
**Solution:**
1. Verify `NEXUS_API_URL` is set: `curl http://localhost/api/health` from inside container
2. Test from host: `curl https://marcoby.nexus.marcoby.com/api/health`
3. Check firewall/network access

### Problem: OpenClaw still using Anthropic instead of OpenRouter
**Solution:**
1. Check that OpenRouter API key is stored in Nexus (Settings → Integrations & AI Providers → AI Providers)
2. Add key if missing
3. Verify nexus agent fallback chain is correct (should start with OpenRouter, not Anthropic)

## Manual Configuration (Emergency Fix)

If auto-config doesn't work, you can manually configure:

```bash
# SSH to mar-ubu01
ssh mar-ubu01

# Get container ID
CONTAINER_ID=a0af2813b9dd

# Backup current config
docker exec $CONTAINER_ID cp /data/.openclaw/openclaw.json /data/.openclaw/openclaw.json.backup

# Update openclaw.json with NEXUS_API_URL
docker exec $CONTAINER_ID bash -c 'cat /data/.openclaw/openclaw.json | jq ".env.NEXUS_API_URL = \"https://marcoby.nexus.marcoby.com/api\"" > /tmp/openclaw.json && mv /tmp/openclaw.json /data/.openclaw/openclaw.json'

# Restart container
docker restart $CONTAINER_ID

# Verify
docker exec $CONTAINER_ID cat /data/.openclaw/openclaw.json | jq '.env.NEXUS_API_URL'
```

## Testing End-to-End

After configuration is verified:

1. **Start a Nexus conversation**
   - Go to marcoby.nexus.marcoby.com
   - Start a new chat with the "nexus" agent

2. **Monitor the flow:**
   - Nexus orchestrates chat to OpenClaw
   - OpenClaw toolbridge fetches your credentials from Nexus
   - OpenClaw uses your OpenRouter key to call Anthropic Claude
   - Response streams back through Nexus to your browser

3. **Check OpenClaw logs for success:**
   ```bash
   ssh mar-ubu01 'docker logs a0af2813b9dd | grep -i "openrouter\|credential\|sync" | tail -10'
   ```

## Integration with Nexus Deployment

The complete Nexus deployment flow should:

1. Deploy Nexus backend
2. Deploy OpenClaw via Coolify
3. Set `NEXUS_FRONTEND_URL` env var on OpenClaw
4. Auto-config hook runs on OpenClaw startup
5. nexus-toolbridge can reach Nexus to fetch credentials
6. Conversations work end-to-end

## Files Modified

- ✓ `openclaw-coolify/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/handler.ts` - Hook implementation
- ✓ `openclaw-coolify/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/HOOK.md` - Hook manifest
- ✓ `openclaw-coolify/extensions/nexus-toolbridge/hooks/auto-configure-nexus-url/README.md` - Documentation
- ✓ `Nexus/apps/server/src/services/coolifyClient.ts` - Added `configureOpenClawNexusIntegration()`

## Next Steps

1. **Deploy to mar-ubu01:**
   - Set `NEXUS_FRONTEND_URL=https://marcoby.nexus.marcoby.com` in Coolify
   - Restart OpenClaw container

2. **Verify configuration:**
   - Check `NEXUS_API_URL` is set in openclaw.json
   - Check toolbridge logs show successful credential fetch

3. **Test conversations:**
   - Start a chat with the nexus agent
   - Verify it uses OpenRouter (not Anthropic)
   - Check OpenRouter credits are being used

## Support

If you encounter issues:
1. Check troubleshooting section above
2. Review logs: `docker logs a0af2813b9dd | grep -A 5 "auto-configure"`
3. Verify environment variables are correctly set
4. Ensure NEXUS_API_URL ends with `/api` (if set manually)
