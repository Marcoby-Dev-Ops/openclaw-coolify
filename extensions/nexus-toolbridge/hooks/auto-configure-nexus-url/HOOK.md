---
name: "auto-configure-nexus-url"
description: "Automatically discovers and configures NEXUS_API_URL from environment variables on OpenClaw startup"
metadata: {"openclaw":{"events":["system:startup","system:initialize"]}}
---

# Auto-Configure Nexus URL

Runs on OpenClaw startup to discover the Nexus API URL from environment variables and automatically
configure it in the openclaw.json configuration file. This enables the nexus-toolbridge plugin to
reach the Nexus backend and fetch credentials at runtime.

## Discovery Order

1. `NEXUS_API_URL` environment variable (direct API URL)
2. `NEXUS_FRONTEND_URL` environment variable (frontend URL, `/api` appended automatically)
3. Coolify metadata (future: inspect container labels for Nexus endpoint)

## Setup

When deploying OpenClaw via Nexus on Coolify, ensure one of these environment variables is set:

```bash
# Option 1: Direct API URL
NEXUS_API_URL=https://marcoby.nexus.marcoby.com/api

# Option 2: Frontend URL (auto-appends /api)
NEXUS_FRONTEND_URL=https://marcoby.nexus.marcoby.com
```
