import * as pluginSdk from "openclaw/plugin-sdk";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import crypto from "crypto";
import fs from "fs";
import path from "path";
import { Buffer } from "buffer";

type ToolSchema = Record<string, unknown>;

const emptyPluginConfigSchema =
  typeof (pluginSdk as { emptyPluginConfigSchema?: unknown }).emptyPluginConfigSchema === "function"
    ? (pluginSdk as { emptyPluginConfigSchema: () => ToolSchema }).emptyPluginConfigSchema
    : () => ({
        type: "object",
        additionalProperties: false,
        properties: {},
      } satisfies ToolSchema);

function toPluginToolResult(payload: unknown): unknown {
  const helper = (pluginSdk as { jsonResult?: (value: unknown) => unknown }).jsonResult;
  if (typeof helper === "function") {
    return helper(payload);
  }

  if (
    payload &&
    typeof payload === "object" &&
    "result" in (payload as Record<string, unknown>)
  ) {
    return (payload as Record<string, unknown>).result;
  }

  return payload;
}

interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: ToolSchema;
}

interface CatalogResponse {
  success?: boolean;
  metadata?: {
    catalogVersion?: string;
  };
  tools?: Array<{
    name?: string;
    description?: string;
    inputSchema?: ToolSchema;
    parameters?: ToolSchema;
  }>;
}

interface ToolCatalogState {
  tools: ToolDefinition[];
  version: string | null;
  etag: string | null;
  fetchedAt: number;
  refreshPromise: Promise<ToolDefinition[]> | null;
}

// ---------------------------------------------------------------------------
// JIT Credential Cache
// ---------------------------------------------------------------------------
interface CredentialCacheEntry {
  keys: Record<string, string>;
  expiry: number;
}

const CREDENTIALS_TTL_MS = 300_000; // 5 minutes
const credentialCache = new Map<string, CredentialCacheEntry>();

// Most-recent session key — updated every time the registerTool factory is
// called so that tool execute() closures always resolve the latest identity
// even if they were instantiated before the session was fully established.
let latestSessionKey: string | undefined;

// ---------------------------------------------------------------------------
// Local tool execution — tools that can run directly inside the OpenClaw
// container without a network round-trip back to Nexus.
// ---------------------------------------------------------------------------
const LOCAL_TOOL_NAMES = new Set([
  "nexus_read_file",
  "nexus_write_file",
  "nexus_list_files",
]);

const SHARED_WORKSPACE_ROOT = "/data/workspace";
const SYSTEM_WORKSPACE_DIR = path.join(SHARED_WORKSPACE_ROOT, "main");

function sanitizeWorkspaceUserId(userId: string): string {
  const trimmed = String(userId || "").trim();
  if (!trimmed) return "";
  return trimmed.replace(/[^A-Za-z0-9._-]/g, "_");
}

function resolveWorkspaceBase(userId: string): string {
  const safeUserId = sanitizeWorkspaceUserId(userId);
  if (!safeUserId) return SYSTEM_WORKSPACE_DIR;

  // Per-user workspace directory.  The shared volume is mounted at
  // /data/workspace with per-user sub-dirs (managed by Nexus's
  // workspaceFileService).  Fall back to the legacy flat path only if the
  // per-user directory does not exist yet.
  const perUser = path.join(SHARED_WORKSPACE_ROOT, safeUserId);
  if (fs.existsSync(perUser)) return perUser;

  // Ensure the per-user directory exists on first use
  try {
    fs.mkdirSync(perUser, { recursive: true });
    return perUser;
  } catch {
    // Last resort — use the dedicated system workspace rather than the root.
    return SYSTEM_WORKSPACE_DIR;
  }
}

function sanitizeFilename(filename: string): string {
  // Prevent path traversal
  const normalized = path.normalize(filename).replace(/^(\.\.(\/|\\|$))+/, "");
  if (normalized.startsWith("/") || normalized.includes("..")) {
    throw new Error("Invalid filename: path traversal is not allowed");
  }
  return normalized;
}

async function executeLocalTool(
  toolName: string,
  args: Record<string, unknown>,
  userId: string,
  api: OpenClawPluginApi,
): Promise<unknown> {
  const workspaceBase = resolveWorkspaceBase(userId);

  if (toolName === "nexus_read_file") {
    const filename = sanitizeFilename(String(args.filename || ""));
    const filePath = path.join(workspaceBase, filename);
    if (!fs.existsSync(filePath)) {
      throw new Error(`File not found: ${filename}`);
    }
    const content = fs.readFileSync(filePath);
    const encoding = String(args.encoding || "utf-8");
    return {
      content: encoding === "base64" ? content.toString("base64") : content.toString("utf-8"),
      filename,
      encoding,
      size: content.length,
    };
  }

  if (toolName === "nexus_write_file") {
    const filename = sanitizeFilename(String(args.filename || ""));
    const filePath = path.join(workspaceBase, filename);
    const parentDir = path.dirname(filePath);
    if (!fs.existsSync(parentDir)) fs.mkdirSync(parentDir, { recursive: true });
    const encoding = String(args.encoding || "utf-8");
    const buffer =
      encoding === "base64"
        ? Buffer.from(String(args.content || ""), "base64")
        : Buffer.from(String(args.content || ""), "utf-8");
    fs.writeFileSync(filePath, buffer);
    api.logger.info(`[nexus-toolbridge] Local write: ${filename} (${buffer.length} bytes)`);
    return { success: true, filename, size: buffer.length };
  }

  if (toolName === "nexus_list_files") {
    const subPath = String(args.path || "");
    const searchPath = subPath ? path.join(workspaceBase, sanitizeFilename(subPath)) : workspaceBase;
    if (!fs.existsSync(searchPath)) return { files: [] };
    const entries: string[] = fs.readdirSync(searchPath);
    const files = entries.map((name: string) => {
      const fullPath = path.join(searchPath, name);
      try {
        const stat = fs.statSync(fullPath);
        return { name, size: stat.size, mtime: stat.mtime.toISOString(), isDirectory: stat.isDirectory() };
      } catch {
        return { name, size: 0, mtime: null, isDirectory: false };
      }
    });
    return { files, path: subPath || "/" };
  }

  throw new Error(`Local tool ${toolName} not implemented`);
}

// ---------------------------------------------------------------------------
// JIT Credential Sync — fetches per-user API keys from Nexus on demand
// instead of requiring docker exec injection.
// ---------------------------------------------------------------------------
async function syncCredentialsIfNeeded(
  api: OpenClawPluginApi,
  userId: string,
): Promise<void> {
  const cached = credentialCache.get(userId);
  if (cached && cached.expiry > Date.now()) return;

  const nexusApiUrl = resolveNexusApiUrl();
  const apiKey = resolveNexusOpenClawApiKey();

  try {
    const resp = await fetch(`${nexusApiUrl}/api/openclaw/credentials`, {
      headers: {
        "X-OpenClaw-Api-Key": apiKey,
        "X-Nexus-User-Id": userId,
        "Content-Type": "application/json",
      },
    });

    if (!resp.ok) {
      api.logger.warn(`[nexus-toolbridge] Credential sync returned HTTP ${resp.status} for user ${userId}`);
      return;
    }

    const data = (await resp.json()) as { success?: boolean; credentials?: Record<string, string> };
    if (data.success && data.credentials) {
      credentialCache.set(userId, {
        keys: data.credentials,
        expiry: Date.now() + CREDENTIALS_TTL_MS,
      });
      api.logger.info(
        `[nexus-toolbridge] JIT credential sync: ${Object.keys(data.credentials).length} providers for user ${userId}`,
      );
    }
  } catch (error) {
    const errMsg = error instanceof Error ? error.message : String(error);
    api.logger.error(`[nexus-toolbridge] Credential sync failed for ${userId}: ${errMsg}`);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function normalizeBaseUrl(input: string | undefined | null): string {
  const raw = String(input ?? "").trim();
  if (!raw) return "";

  let url = raw.replace(/\/+$/, "");
  if (!/^https?:\/\//i.test(url)) {
    const isLocal =
      url.includes("localhost") ||
      url.includes("127.0.0.1") ||
      url.includes("host.docker.internal");
    url = `${isLocal ? "http" : "https"}://${url}`;
  }

  try {
    new URL(url);
  } catch (error) {
    console.error(`[nexus-toolbridge] Invalid URL after normalization: ${url}`, error);
    return "https://napp.marcoby.net";
  }

  return url;
}

function normalizeInputSchema(input: unknown): ToolSchema {
  if (input && typeof input === "object" && !Array.isArray(input)) {
    return input as ToolSchema;
  }
  return {
    type: "object",
    properties: {},
    additionalProperties: false,
  };
}

const LEGACY_SESSION_KEY_MARKERS = ["openai-user:", "nexus-openai-user:", "openresponses-user:"] as const;

function extractNexusUserFromSessionKey(
  sessionKey: string | undefined,
): { userId: string; conversationId: string | null } | null {
  const raw = String(sessionKey ?? "").trim();
  if (!raw) return null;

  const lowered = raw.toLowerCase();
  for (const marker of LEGACY_SESSION_KEY_MARKERS) {
    const idx = lowered.indexOf(marker);
    if (idx < 0) continue;

    const after = raw.slice(idx + marker.length);
    const parts = after.split(":").filter(Boolean);
    if (parts.length === 0) continue;

    return {
      userId: parts[0],
      conversationId: parts.length > 1 ? parts.slice(1).join(":") : null,
    };
  }

  return null;
}

function resolveNexusApiUrl(): string {
  return (
    normalizeBaseUrl(process.env.NEXUS_API_URL) ||
    normalizeBaseUrl(process.env.NEXUS_BASE_URL) ||
    "https://napp.marcoby.net"
  );
}

function resolveNexusOpenClawApiKey(): string {
  return (
    String(process.env.NEXUS_OPENCLAW_API_KEY || "").trim() ||
    String(process.env.OPENCLAW_API_KEY || "").trim() ||
    String(process.env.OPENCLAW_GATEWAY_TOKEN || "").trim() ||
    "sk-openclaw-local"
  );
}

function resolveCatalogTtlMs(): number {
  const raw = Number.parseInt(String(process.env.NEXUS_TOOL_CATALOG_TTL_MS || "30000"), 10);
  if (!Number.isFinite(raw) || raw <= 0) return 30000;
  return Math.max(5000, raw);
}

const TOOL_CATALOG_TTL_MS = resolveCatalogTtlMs();

// ---------------------------------------------------------------------------
// Fallback tool definitions — used when Nexus catalog is unreachable
// ---------------------------------------------------------------------------
const FALLBACK_TOOL_DEFINITIONS: ToolDefinition[] = [
  {
    name: "nexus_m365_capabilities",
    description: "Show Microsoft 365 capability availability for this user, including missing scopes and which tools are usable now.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "nexus_get_user_identity_context",
    description: "Fetch structured onboarding identity context for this Nexus user.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "nexus_get_integration_status",
    description: "Get current integration status for the signed-in Nexus user.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "nexus_resolve_email_provider",
    description: "Resolve email provider from MX records (Microsoft 365 vs Google Workspace).",
    inputSchema: {
      type: "object",
      required: ["email"],
      properties: { email: { type: "string" } },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_start_integration_connection",
    description: "Start OAuth connect flow for a supported Nexus business integration.",
    inputSchema: {
      type: "object",
      required: ["provider"],
      properties: {
        provider: {
          type: "string",
          enum: ["microsoft", "microsoft365", "google", "google_workspace", "google-workspace", "google_analytics", "google-analytics", "github", "hubspot", "slack"],
        },
        redirectUri: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_search_emails",
    description: "Search connected inbox emails by date range, sender(s), and free-text query.",
    inputSchema: {
      type: "object",
      properties: {
        provider: { type: "string", description: '"auto", "all", "microsoft", or "google-workspace".' },
        datePreset: { type: "string" },
        startDate: { type: "string" },
        endDate: { type: "string" },
        from: { type: "string" },
        query: { type: "string" },
        unreadOnly: { type: "boolean" },
        limit: { type: "number" },
        timezone: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_send_email",
    description: "Send an email to specific recipients with a subject, body, and optional CC, BCC.",
    inputSchema: {
      type: "object",
      required: ["to", "subject", "body"],
      properties: {
        provider: { type: "string", enum: ["auto", "microsoft", "google-workspace"] },
        to: { type: "string" },
        subject: { type: "string" },
        body: { type: "string" },
        cc: { type: "string" },
        bcc: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_get_calendar_events",
    description: "Fetch upcoming calendar events for a specific date range.",
    inputSchema: {
      type: "object",
      properties: {
        provider: { type: "string", enum: ["auto", "microsoft", "google-workspace"] },
        datePreset: { type: "string" },
        startDate: { type: "string" },
        endDate: { type: "string" },
        limit: { type: "number" },
        timezone: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_list_files",
    description: "List all files in the current user's workspace.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "nexus_read_file",
    description: "Read the contents of a file from the user's workspace.",
    inputSchema: {
      type: "object",
      required: ["filename"],
      properties: { filename: { type: "string", description: "Name of the file to read" } },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_write_file",
    description: "Create or overwrite a file in the user's workspace.",
    inputSchema: {
      type: "object",
      required: ["filename", "content"],
      properties: {
        filename: { type: "string", description: "Name of the file to create" },
        content: { type: "string", description: "File content." },
        encoding: { type: "string", enum: ["utf-8", "base64"], default: "utf-8" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_generate_image",
    description: "Generate high-quality images and illustrations. Images are saved to your workspace.",
    inputSchema: {
      type: "object",
      required: ["prompt"],
      properties: {
        prompt: { type: "string", description: "Detailed description of the image to generate" },
        aspect_ratio: { type: "string", enum: ["1:1", "16:9", "4:3", "3:2"], default: "1:1" },
        filename: { type: "string", description: "Optional filename for the saved image" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "create_integration_from_url",
    description: "Create a new Specialized Agent and Tool Integration by reading API documentation from a URL.",
    inputSchema: {
      type: "object",
      required: ["url"],
      properties: {
        url: { type: "string", description: "URL of the API documentation" },
        name: { type: "string", description: "Optional name for its integration" },
      },
      additionalProperties: false,
    },
  },
];

// ---------------------------------------------------------------------------
// Tool Catalog State & Refresh
// ---------------------------------------------------------------------------

const toolCatalogState: ToolCatalogState = {
  tools: [],
  version: null,
  etag: null,
  fetchedAt: 0,
  refreshPromise: null,
};

function normalizeCatalogTool(tool: NonNullable<CatalogResponse["tools"]>[number]): ToolDefinition | null {
  const name = String(tool?.name || "").trim();
  if (!name) return null;

  return {
    name,
    description: String(tool?.description || "").trim() || name,
    inputSchema: normalizeInputSchema(tool?.inputSchema || tool?.parameters),
  };
}

function dedupeToolDefinitions(
  tools: ToolDefinition[],
): { tools: ToolDefinition[]; duplicates: string[] } {
  const seen = new Set<string>();
  const duplicates: string[] = [];
  const deduped: ToolDefinition[] = [];

  for (const tool of tools) {
    if (seen.has(tool.name)) {
      duplicates.push(tool.name);
      continue;
    }
    seen.add(tool.name);
    deduped.push(tool);
  }

  return { tools: deduped, duplicates };
}

async function fetchCatalogFromNexus(api: OpenClawPluginApi): Promise<{
  tools: ToolDefinition[];
  version: string | null;
  etag: string | null;
  notModified: boolean;
}> {
  const endpoint = `${resolveNexusApiUrl()}/api/openclaw/tools/catalog`;
  const response = await fetch(endpoint, {
    headers: {
      "X-OpenClaw-Api-Key": resolveNexusOpenClawApiKey(),
      "Content-Type": "application/json",
      ...(toolCatalogState.etag ? { "If-None-Match": toolCatalogState.etag } : {}),
    },
  });

  if (response.status === 304) {
    return {
      tools: toolCatalogState.tools,
      version: toolCatalogState.version,
      etag: toolCatalogState.etag,
      notModified: true,
    };
  }

  if (!response.ok) {
    throw new Error(`Catalog fetch failed with HTTP ${response.status}`);
  }

  const payload = (await response.json()) as CatalogResponse;
  const normalizedTools = (payload.tools || [])
    .map((tool) => normalizeCatalogTool(tool))
    .filter((tool): tool is ToolDefinition => Boolean(tool));

  const { tools, duplicates } = dedupeToolDefinitions(normalizedTools);

  if (duplicates.length > 0) {
    api.logger.warn(
      `[nexus-toolbridge] Deduped ${duplicates.length} duplicate tool definitions from Nexus catalog: ${duplicates.join(", ")}`,
    );
  }

  if (tools.length === 0) {
    api.logger.warn("[nexus-toolbridge] Nexus catalog returned zero tools; keeping current cache");
  }

  return {
    tools,
    version: String(payload.metadata?.catalogVersion || "").trim() || null,
    etag: String(response.headers.get("etag") || "").trim() || null,
    notModified: false,
  };
}

async function refreshCatalog(api: OpenClawPluginApi, reason: string): Promise<ToolDefinition[]> {
  if (toolCatalogState.refreshPromise) {
    return toolCatalogState.refreshPromise;
  }

  toolCatalogState.refreshPromise = (async () => {
    try {
      const { tools, version, etag, notModified } = await fetchCatalogFromNexus(api);

      if (notModified) {
        toolCatalogState.fetchedAt = Date.now();
        return toolCatalogState.tools.length > 0 ? toolCatalogState.tools : FALLBACK_TOOL_DEFINITIONS;
      }

      if (tools.length > 0) {
        const previousVersion = toolCatalogState.version;
        toolCatalogState.tools = tools;
        toolCatalogState.version = version;
        toolCatalogState.etag = etag;
        toolCatalogState.fetchedAt = Date.now();

        if (previousVersion !== version) {
          api.logger.info(
            `[nexus-toolbridge] Refreshed tool catalog (${reason}): ${tools.length} tools` +
              (version ? ` version=${version}` : ""),
          );
        }
      } else {
        toolCatalogState.fetchedAt = Date.now();
      }
    } catch (error) {
      const errMsg = error instanceof Error ? error.message : String(error);
      api.logger.error(`[nexus-toolbridge] Failed to refresh tool catalog (${reason}): ${errMsg}`);
      toolCatalogState.fetchedAt = Date.now();
    } finally {
      toolCatalogState.refreshPromise = null;
    }

    return toolCatalogState.tools.length > 0 ? toolCatalogState.tools : FALLBACK_TOOL_DEFINITIONS;
  })();

  return toolCatalogState.refreshPromise;
}

function getAvailableToolDefinitions(api: OpenClawPluginApi): ToolDefinition[] {
  const now = Date.now();
  const hasCache = toolCatalogState.tools.length > 0;
  const isStale = now - toolCatalogState.fetchedAt >= TOOL_CATALOG_TTL_MS;

  if (!hasCache) {
    void refreshCatalog(api, "cold-start");
    return FALLBACK_TOOL_DEFINITIONS.filter((tool) => tool.name.startsWith("nexus_"));
  }

  if (isStale && !toolCatalogState.refreshPromise) {
    void refreshCatalog(api, "ttl-expired");
  }

  return toolCatalogState.tools.filter((tool) => tool.name.startsWith("nexus_"));
}

// ---------------------------------------------------------------------------
// Remote tool execution — calls back into Nexus for tools that need
// server-side data (integrations, email, calendar, etc.)
// ---------------------------------------------------------------------------

async function callNexusTool(params: {
  api: OpenClawPluginApi;
  userId: string;
  toolName: string;
  args: Record<string, unknown>;
  toolCallId: string;
  signal?: AbortSignal | undefined;
}): Promise<unknown> {
  const nexusApiUrl = resolveNexusApiUrl();
  const apiKey = resolveNexusOpenClawApiKey();

  const correlationId = params.toolCallId || crypto.randomUUID();
  const endpoint = `${nexusApiUrl}/api/openclaw/tools/execute`;

  try {
    new URL(endpoint);
  } catch (error) {
    params.api.logger.error(`[nexus-toolbridge] Invalid endpoint URL: ${endpoint}`, error);
    throw new Error(`Failed to parse URL from ${endpoint}`);
  }

  params.api.logger.info(
    `[nexus-toolbridge] tool=${params.toolName} userId=${params.userId} corr=${correlationId} endpoint=${endpoint}`,
  );

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-OpenClaw-Api-Key": apiKey,
      "X-Nexus-User-Id": params.userId,
      "X-Correlation-Id": correlationId,
    },
    body: JSON.stringify({ tool: params.toolName, args: params.args ?? {} }),
    signal: params.signal,
  });

  const payload = await response.json().catch(() => ({}));

  if (!response.ok) {
    const errMsg =
      (payload && typeof payload === "object" && "error" in payload && (payload as { error?: string }).error) ||
      `Nexus tool execution failed (HTTP ${response.status})`;
    params.api.logger.error(`[nexus-toolbridge] Request failed: ${String(errMsg)}`);
    throw new Error(String(errMsg));
  }

  if (payload && typeof payload === "object" && "result" in payload) {
    return (payload as { result: unknown }).result;
  }

  return payload;
}

// ---------------------------------------------------------------------------
// Plugin registration
// ---------------------------------------------------------------------------

const nexusToolbridgePlugin = {
  id: "nexus-toolbridge",
  name: "Nexus Tool Bridge",
  description:
    "Expose Nexus integration tools to OpenClaw. Executes file tools locally for speed; " +
    "proxies all other tools to Nexus /api/openclaw/tools/execute. " +
    "Syncs per-user credentials via JIT API.",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    void refreshCatalog(api, "startup");

    const refreshTimer = setInterval(() => {
      void refreshCatalog(api, "interval");
    }, TOOL_CATALOG_TTL_MS);
    // Only call unref if available (Node.js)
    if (typeof (refreshTimer as any).unref === "function") {
      (refreshTimer as any).unref();
    }

    api.registerTool((ctx: any) => {
      const sessionKey = ctx.sessionKey;
      const toolDefinitions = getAvailableToolDefinitions(api);

      // Keep module-level key up-to-date so that execute() closures from
      // earlier factory evaluations can still resolve the current identity.
      if (sessionKey) {
        latestSessionKey = sessionKey;
      }

      // Fire-and-forget JIT credential sync for this user session
      const nexusUser = extractNexusUserFromSessionKey(sessionKey);
      if (nexusUser?.userId) {
        void syncCredentialsIfNeeded(api, nexusUser.userId);
      }

      return toolDefinitions.map((tool) => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.inputSchema,
        execute: async (
          toolCallId: string,
          params: unknown,
          signal?: AbortSignal | undefined,
        ) => {
          const args =
            params && typeof params === "object" && !Array.isArray(params)
              ? (params as Record<string, unknown>)
              : {};

          // Resolve user identity from the richest available runtime context.
          const metadata = (ctx && typeof ctx === "object" && ctx.metadata && typeof ctx.metadata === "object")
            ? ctx.metadata as Record<string, unknown>
            : {};
          const metadataUserId =
            (typeof metadata.userId === 'string' && metadata.userId.trim())
            || (typeof metadata.nexusUserId === 'string' && metadata.nexusUserId.trim())
            || '';
          const effectiveSessionKey = sessionKey
            || latestSessionKey
            || (typeof metadata.sessionKey === 'string' ? metadata.sessionKey : '')
            || (typeof metadata.nexusSessionKey === 'string' ? metadata.nexusSessionKey : '');
          const userId =
            (typeof ctx.userId === 'string' && ctx.userId.trim())
            || metadataUserId
            || extractNexusUserFromSessionKey(effectiveSessionKey)?.userId;
          if (!userId) {
            throw new Error("Cannot resolve Nexus user id for tool execution. Expected canonical Nexus identity context or a legacy sessionKey containing openai-user:<nexusUserId>:<conversationId>.");
          }

          // Local execution for file tools (avoids network round-trip)
          if (LOCAL_TOOL_NAMES.has(tool.name)) {
            try {
              const localResult = await executeLocalTool(tool.name, args, userId, api);
              return toPluginToolResult({ tool: tool.name, result: localResult });
            } catch (localErr) {
              // If local execution fails, fall through to remote
              api.logger.warn(
                `[nexus-toolbridge] Local execution failed for ${tool.name}, falling back to remote: ${localErr instanceof Error ? localErr.message : String(localErr)}`,
              );
            }
          }

          // Remote execution via Nexus API
          const result = await callNexusTool({
            api,
            userId,
            toolName: tool.name,
            args,
            toolCallId,
            signal,
          });

          return toPluginToolResult({
            tool: tool.name,
            result,
          });
        },
      }));
    });
  },
};

export default nexusToolbridgePlugin;
