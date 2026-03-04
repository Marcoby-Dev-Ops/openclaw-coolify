import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { emptyPluginConfigSchema, jsonResult } from "openclaw/plugin-sdk";
import crypto from "node:crypto";

type ToolSchema = Record<string, unknown>;

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

function extractNexusUserFromSessionKey(
  sessionKey: string | undefined,
): { userId: string; conversationId: string | null } | null {
  const raw = String(sessionKey ?? "").trim();
  if (!raw) return null;

  const lowered = raw.toLowerCase();
  const marker = "openai-user:";
  const idx = lowered.indexOf(marker);
  if (idx < 0) return null;

  const after = raw.slice(idx + marker.length);
  const parts = after.split(":").filter(Boolean);
  if (parts.length === 0) return null;

  return {
    userId: parts[0],
    conversationId: parts.length > 1 ? parts.slice(1).join(":") : null,
  };
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
      properties: {
        email: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_start_email_connection",
    description: "Start OAuth connection flow for an email provider.",
    inputSchema: {
      type: "object",
      required: ["provider"],
      properties: {
        provider: { type: "string", description: 'Provider slug, e.g. "microsoft" or "google-workspace".' },
        redirectUri: { type: "string" },
      },
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
          enum: [
            "microsoft",
            "microsoft365",
            "google",
            "google_workspace",
            "google-workspace",
            "google_analytics",
            "google-analytics",
            "github",
            "hubspot",
            "slack",
          ],
        },
        redirectUri: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_start_github_connection",
    description: "Start OAuth connect flow for GitHub so Nexus can access private repositories via a stored user integration.",
    inputSchema: {
      type: "object",
      properties: {
        redirectUri: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_github_auth_status",
    description: "Check whether the current Nexus user has a connected GitHub OAuth integration and inspect token readiness.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "nexus_get_provider_auth_status",
    description: "Check whether the current Nexus user has a connected OAuth integration for a supported provider.",
    inputSchema: {
      type: "object",
      required: ["provider"],
      properties: {
        provider: {
          type: "string",
          enum: [
            "microsoft",
            "microsoft365",
            "google",
            "google_workspace",
            "google-workspace",
            "google_analytics",
            "google-analytics",
            "github",
            "hubspot",
            "slack",
          ],
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_list_github_repositories",
    description: "List the current user's GitHub repositories after connecting GitHub.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number" },
        visibility: { type: "string", enum: ["all", "public", "private"] },
        type: { type: "string", enum: ["all", "owner", "member"] },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_list_hubspot_contacts",
    description: "List HubSpot contacts for the current user after connecting HubSpot.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_list_slack_channels",
    description: "List Slack channels for the current user after connecting Slack.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number" },
        cursor: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_get_google_analytics_accounts",
    description: "List Google Analytics accounts and properties available to the current user.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_connect_imap",
    description: "Connect an IMAP inbox using host/port credentials (fallback when OAuth is unavailable).",
    inputSchema: {
      type: "object",
      required: ["email", "host", "port", "username", "password"],
      properties: {
        email: { type: "string" },
        host: { type: "string" },
        port: { type: "number" },
        username: { type: "string" },
        password: { type: "string" },
        useSSL: { type: "boolean" },
        providerHint: { type: "string" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_test_integration_connection",
    description: "Test saved OAuth connection health for a provider.",
    inputSchema: {
      type: "object",
      required: ["provider"],
      properties: {
        provider: { type: "string" },
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
        timezone: { type: "string", description: "IANA timezone (e.g. America/Chicago). Defaults to user profile timezone or UTC." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_send_email",
    description: "Send an email to specific recipients with a subject, body, and optional CC, BCC, and attachments.",
    inputSchema: {
      type: "object",
      required: ["to", "subject", "body"],
      properties: {
        provider: { type: "string", enum: ["auto", "microsoft", "google-workspace"], description: "The email provider to use. Defaults to 'auto'." },
        to: { type: "string", description: "A single recipient email address or a comma-separated list." },
        subject: { type: "string", description: "The subject line of the email." },
        body: { type: "string", description: "The main content of the email (HTML or plain text)." },
        cc: { type: "string", description: "Optional recipient email address or comma-separated list." },
        bcc: { type: "string", description: "Optional recipient email address or comma-separated list." },
        attachments: {
          type: "array",
          items: {
            type: "object",
            properties: {
              filename: { type: "string" },
              path: { type: "string" },
              contentType: { type: "string" },
            },
            required: ["filename", "path"],
          },
        },
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
        datePreset: { type: "string", enum: ["today", "last_7_days", "last_30_days", "this_week", "last_week", "this_month", "last_month", "custom"] },
        startDate: { type: "string" },
        endDate: { type: "string" },
        limit: { type: "number" },
        timezone: { type: "string", description: "IANA timezone. Defaults to user profile timezone or UTC." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "nexus_disconnect_integration",
    description: "Disconnect an integration by ID or provider.",
    inputSchema: {
      type: "object",
      properties: {
        integrationId: { type: "string" },
        provider: { type: "string" },
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
      properties: {
        filename: { type: "string", description: "Name of the file to read" },
      },
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
];

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
      api.logger.error(`[nexus-toolbridge] Failed to refresh tool catalog (${reason})`, error);
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
    return FALLBACK_TOOL_DEFINITIONS;
  }

  if (isStale && !toolCatalogState.refreshPromise) {
    void refreshCatalog(api, "ttl-expired");
  }

  return toolCatalogState.tools;
}

async function callNexusTool(params: {
  api: OpenClawPluginApi;
  sessionKey: string | undefined;
  toolName: string;
  args: Record<string, unknown>;
  toolCallId: string;
  signal?: AbortSignal | undefined;
}): Promise<unknown> {
  const nexusApiUrl = resolveNexusApiUrl();
  const apiKey = resolveNexusOpenClawApiKey();

  const nexusUser = extractNexusUserFromSessionKey(params.sessionKey);
  if (!nexusUser?.userId) {
    throw new Error(
      "Cannot resolve Nexus user id for tool execution. " +
        "Expected sessionKey to contain `openai-user:<nexusUserId>:<conversationId>`.",
    );
  }

  const correlationId = params.toolCallId || crypto.randomUUID();
  const endpoint = `${nexusApiUrl}/api/openclaw/tools/execute`;

  try {
    new URL(endpoint);
  } catch (error) {
    params.api.logger.error(`[nexus-toolbridge] Invalid endpoint URL: ${endpoint}`, error);
    throw new Error(`Failed to parse URL from ${endpoint}`);
  }

  params.api.logger.info(
    `[nexus-toolbridge] tool=${params.toolName} userId=${nexusUser.userId} corr=${correlationId} endpoint=${endpoint}`,
  );

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-OpenClaw-Api-Key": apiKey,
      "X-Nexus-User-Id": nexusUser.userId,
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

const nexusToolbridgePlugin = {
  id: "nexus-toolbridge",
  name: "Nexus Tool Bridge",
  description:
    "Expose Nexus integration tools to OpenClaw by proxying Nexus /api/openclaw/tools/execute.",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    void refreshCatalog(api, "startup");

    const refreshTimer = setInterval(() => {
      void refreshCatalog(api, "interval");
    }, TOOL_CATALOG_TTL_MS);
    refreshTimer.unref?.();

    api.registerTool((ctx) => {
      const sessionKey = ctx.sessionKey;
      const toolDefinitions = getAvailableToolDefinitions(api);

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

          const result = await callNexusTool({
            api,
            sessionKey,
            toolName: tool.name,
            args,
            toolCallId,
            signal,
          });

          return jsonResult({
            tool: tool.name,
            result,
          });
        },
      }));
    });
  },
};

export default nexusToolbridgePlugin;
