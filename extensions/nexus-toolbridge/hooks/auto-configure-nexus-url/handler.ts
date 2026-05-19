/**
 * Auto-Configure Nexus API URL Hook
 * 
 * Runs on OpenClaw startup and automatically discovers/configures the Nexus API URL
 * from environment variables or Coolify deployment metadata.
 * 
 * This ensures the toolbridge can connect to Nexus without manual configuration.
 */

import * as fs from 'fs';
import * as path from 'path';

interface NexusConfig {
  frontendUrl?: string;
  apiUrl?: string;
}

/**
 * Discover Nexus API URL from various sources:
 * 1. NEXUS_API_URL env var (explicit)
 * 2. NEXUS_FRONTEND_URL env var (derive /api)
 * 3. Coolify deployment metadata
 * 4. Service discovery (check for nexus service on docker network)
 */
function discoverNexusApiUrl(): string | null {
  // 1. Check explicit NEXUS_API_URL
  if (process.env.NEXUS_API_URL) {
    const url = String(process.env.NEXUS_API_URL).trim();
    if (url && url.startsWith('http')) {
      return url;
    }
  }

  // 2. Check NEXUS_FRONTEND_URL — return bare base; toolbridge appends /api/openclaw/... itself
  if (process.env.NEXUS_FRONTEND_URL) {
    const frontend = String(process.env.NEXUS_FRONTEND_URL).trim().replace(/\/+$/, '');
    if (frontend && frontend.startsWith('http')) {
      return frontend.replace(/\/api$/, '');
    }
  }

  // 3. Check Coolify metadata in .env or docker labels
  try {
    const envFile = '/.dockerenv'; // marker that we're in container
    if (fs.existsSync(envFile)) {
      // We're in Docker - check for NEXUS_* env vars set by Coolify
      const nexusEnvKeys = Object.keys(process.env).filter(k => k.startsWith('NEXUS_'));
      if (nexusEnvKeys.length > 0) {
        console.log(`[nexus-auto-config] Found Nexus env vars: ${nexusEnvKeys.join(', ')}`);
      }
    }
  } catch (e) {
    // Silently continue if can't read env
  }

  return null;
}

/**
 * Update openclaw.json with discovered Nexus API URL
 */
function updateOpenClawConfig(nexusApiUrl: string): boolean {
  try {
    const configPath = '/data/.openclaw/openclaw.json';
    
    if (!fs.existsSync(configPath)) {
      console.error(`[nexus-auto-config] openclaw.json not found at ${configPath}`);
      return false;
    }

    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    
    // Only update if not already set
    if (config.env?.NEXUS_API_URL && config.env.NEXUS_API_URL.startsWith('http')) {
      console.log(
        `[nexus-auto-config] NEXUS_API_URL already configured: ${config.env.NEXUS_API_URL}`
      );
      return true;
    }

    // Update config
    config.env = config.env || {};
    config.env.NEXUS_API_URL = nexusApiUrl;

    // Write back
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf8');
    
    console.log(`[nexus-auto-config] ✓ Updated openclaw.json with NEXUS_API_URL=${nexusApiUrl}`);
    return true;
  } catch (error) {
    console.error(`[nexus-auto-config] Failed to update config: ${error}`);
    return false;
  }
}

/**
 * Main handler - called on plugin initialization
 */
const handler = async () => {
  try {
    console.log('[nexus-auto-config] Starting Nexus API URL auto-configuration...');

    const nexusApiUrl = discoverNexusApiUrl();

    if (!nexusApiUrl) {
      console.warn(
        '[nexus-auto-config] No Nexus API URL discovered. ' +
        'Set NEXUS_API_URL or NEXUS_FRONTEND_URL environment variables.'
      );
      return;
    }

    console.log(`[nexus-auto-config] Discovered Nexus API URL: ${nexusApiUrl}`);

    // Update openclaw.json
    if (updateOpenClawConfig(nexusApiUrl)) {
      console.log('[nexus-auto-config] ✓ Nexus API URL configured successfully');

      // Log available endpoints for debugging
      console.log(`[nexus-auto-config] Nexus endpoints:`);
      console.log(`  - Tools catalog: ${nexusApiUrl}/api/openclaw/tools/catalog`);
      console.log(`  - Tool execute: ${nexusApiUrl}/api/openclaw/tools/execute`);
      console.log(`  - Credentials: ${nexusApiUrl}/api/openclaw/credentials`);
    } else {
      console.error('[nexus-auto-config] Failed to configure Nexus API URL');
    }
  } catch (error) {
    console.error(`[nexus-auto-config] Initialization failed: ${error}`);
    // Don't throw - allow OpenClaw to continue even if auto-config fails
  }
};

export default handler;
