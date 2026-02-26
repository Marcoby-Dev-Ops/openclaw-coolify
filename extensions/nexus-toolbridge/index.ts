import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { emptyPluginConfigSchema, jsonResult } from "openclaw/plugin-sdk";
import crypto from "node:crypto";

function normalizeBaseUrl(input: string | undefined | null): string {
  const raw = String(input ?? "").trim();
  if (!raw) return "";

  // Remove trailing slashes
  let url = raw.replace(/\/+$/, "");

  // Ensure protocol is present
  if (!/^https?:\/\//i.test(url)) {
    // Check if it's a local address
    const isLocal = url.includes('localhost') || url.includes('127.0.0.1') || url.includes('host.docker.internal');
    url = (isLocal ? "http://" : "https://") + url;
  }

  // Validate URL format
  try {
    new URL(url);
    console.log(`[nexus-toolbridge] Normalized URL: ${url}`);
  } catch (e) {
    console.error(`[nexus-toolbridge] Invalid URL after normalization: ${url}`, e);
    // Return a safe default if URL is invalid
    return "https://napi.marcoby.net";
  }

  return url;
}

function extractNexusUserFromSessionKey(
  sessionKey: string | undefined,
): { userId: string; conversationId: string | null } | null {
  const raw = String(sessionKey ?? "").trim();
  if (!raw) return null;

  // Nexus calls OpenClaw /v1/chat/completions with:
  //   user = "<nexusUserId>:<conversationId>"
  // OpenClaw maps that to a sessionKey like:
  //   agent:<agentId>:openai-user:<nexusUserId>:<conversationId>
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
    "https://napi.marcoby.net"
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

  // Validate the endpoint URL
  try {
    new URL(endpoint);
  } catch (e) {
    params.api.logger.error(`[nexus-toolbridge] Invalid endpoint URL: ${endpoint}`, e);
    throw new Error(`Failed to parse URL from ${endpoint}`);
  }

  params.api.logger.info(
    `[nexus-toolbridge] tool=${params.toolName} userId=${nexusUser.userId} corr=${correlationId} endpoint=${endpoint}`,
  );

  try {
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

    const payload = await response.json().catch((e) => {
      params.api.logger.error(`[nexus-toolbridge] Failed to parse JSON response: ${e.message}`);
      return {};
    });

    if (!response.ok) {
      const errMsg =
        (payload && typeof payload === "object" && "error" in payload && (payload as any).error) ||
        `Nexus tool execution failed (HTTP ${response.status})`;
      params.api.logger.error(`[nexus-toolbridge] Request failed: ${errMsg}`);
      throw new Error(String(errMsg));
    }

    // Expected: { success: true, tool: "...", result: ... }
    if (payload && typeof payload === "object" && "result" in payload) {
      return (payload as any).result;
    }
    return payload;
  } catch (e) {
    params.api.logger.error(`[nexus-toolbridge] Tool execution error: ${e.message}`);
    throw e;
  }
}

const nexusToolbridgePlugin = {
  id: "nexus-toolbridge",
  name: "Nexus Tool Bridge",
  description: "Expose Nexus integration tools to OpenClaw by proxying Nexus /api/openclaw/tools/execute.",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    // Note: Hooks are loaded via managed hooks directory (/data/.openclaw/hooks/)
    // See: nexus-identity-primer hook

    api.registerTool((ctx) => {
      const sessionKey = ctx.sessionKey;

      const makeTool = (toolName: string, description: string, parameters: Record<string, unknown>) => {
        return {
          name: toolName,
          description,
          parameters,
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
              toolName,
              args,
              toolCallId,
              signal,
            });

            return jsonResult({
              tool: toolName,
              result,
            });
          },
        };
      };

      return [
        makeTool("nexus_m365_capabilities", "Show Microsoft 365 capability availability for this user, including missing scopes and which tools are usable now.", {
          type: "object",
          properties: {},
        }),
        makeTool("nexus_get_user_identity_context", "Fetch structured onboarding identity context for this Nexus user.", {
          type: "object",
          properties: {},
        }),
        makeTool("nexus_get_integration_status", "Get current integration status for the signed-in Nexus user.", {
          type: "object",
          properties: {},
        }),
        makeTool("nexus_resolve_email_provider", "Resolve email provider from MX records (Microsoft 365 vs Google Workspace).", {
          type: "object",
          required: ["email"],
          properties: {
            email: { type: "string" },
          },
        }),
        makeTool("nexus_start_email_connection", "Start OAuth connection flow for an email provider.", {
          type: "object",
          required: ["provider"],
          properties: {
            provider: { type: "string", description: 'Provider slug, e.g. "microsoft" or "google-workspace".' },
            redirectUri: { type: "string" },
          },
        }),
        makeTool("nexus_connect_imap", "Connect an IMAP inbox using host/port credentials (fallback when OAuth is unavailable).", {
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
        }),
        makeTool("nexus_test_integration_connection", "Test saved OAuth connection health for a provider.", {
          type: "object",
          required: ["provider"],
          properties: {
            provider: { type: "string" },
          },
        }),
        makeTool("nexus_search_emails", "Search connected inbox emails by date range, sender(s), and free-text query.", {
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
        }),
        makeTool("nexus_send_email", "Send an email to specific recipients with a subject, body, and optional CC, BCC, and attachments.", {
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
        }),
        makeTool("nexus_get_calendar_events", "Fetch upcoming calendar events for a specific date range.", {
          type: "object",
          properties: {
            provider: { type: "string", enum: ["auto", "microsoft", "google-workspace"] },
            datePreset: { type: "string", enum: ["today", "last_7_days", "last_30_days", "this_week", "last_week", "this_month", "last_month", "custom"] },
            startDate: { type: "string" },
            endDate: { type: "string" },
            limit: { type: "number" },
            timezone: { type: "string", description: "IANA timezone. Defaults to user profile timezone or UTC." },
          },
        }),
        makeTool("nexus_disconnect_integration", "Disconnect an integration by ID or provider.", {
          type: "object",
          properties: {
            integrationId: { type: "string" },
            provider: { type: "string" },
          },
        }),
        makeTool("nexus_list_files", "List all files in the current user's workspace.", {
          type: "object",
          properties: {},
        }),
        makeTool("nexus_read_file", "Read the contents of a file from the user's workspace.", {
          type: "object",
          required: ["filename"],
          properties: {
            filename: { type: "string", description: "Name of the file to read" },
          },
        }),
        makeTool("nexus_write_file", "Create or overwrite a file in the user's workspace.", {
          type: "object",
          required: ["filename", "content"],
          properties: {
            filename: { type: "string", description: "Name of the file to create" },
            content: { type: "string", description: "File content." },
            encoding: { type: "string", enum: ["utf-8", "base64"], default: "utf-8" },
          },
        }),
        makeTool("create_integration_from_url", "Create a new Specialized Agent and Tool Integration by reading API documentation from a URL.", {
          type: "object",
          required: ["url"],
          properties: {
            url: { type: "string", description: "URL of the API documentation" },
            name: { type: "string", description: "Optional name for its integration" },
          },
        }),
        makeTool("nexus_generate_image", "Generate high-quality images and illustrations. Images are saved to your workspace.", {
          type: "object",
          required: ["prompt"],
          properties: {
            prompt: { type: "string", description: "Detailed description of the image to generate" },
            aspect_ratio: { type: "string", enum: ["1:1", "16:9", "4:3", "3:2"], default: "1:1" },
            filename: { type: "string", description: "Optional filename for the saved image" },
          },
        }),
      ];
    });
  },
};

export default nexusToolbridgePlugin;
