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
    console.log(`[nexus-identity-primer] Normalized URL: ${url}`);
  } catch (e) {
    console.error(`[nexus-identity-primer] Invalid URL after normalization: ${url}`, e);
    // Return a safe default if URL is invalid
    return "https://napi.marcoby.net";
  }
  
  return url;
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

const LEGACY_SESSION_KEY_MARKERS = ["openai-user:", "nexus-openai-user:"] as const;

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

const handler = async (event: any) => {
  if (event?.type !== "command" || event?.action !== "new") return;

  const sessionKey = String(event?.sessionKey || "").trim();
  const nexusUser = extractNexusUserFromSessionKey(sessionKey);
  if (!nexusUser?.userId) return;

  try {
    const response = await fetch(`${resolveNexusApiUrl()}/api/openclaw/tools/execute`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-OpenClaw-Api-Key": resolveNexusOpenClawApiKey(),
        "X-Nexus-User-Id": nexusUser.userId,
      },
      body: JSON.stringify({
        tool: "nexus_get_user_identity_context",
        args: {},
      }),
    });

    const payload = await response.json().catch(() => ({}));
    if (!response.ok || !payload?.success || !payload?.result?.hasIdentity) return;

    const promptContext = String(payload?.result?.promptContext || "").trim();
    if (!promptContext) return;

    const compactContext = promptContext.length > 2400
      ? `${promptContext.slice(0, 2400)}...`
      : promptContext;

    event.messages.push(
      [
        "Loaded Nexus identity context for this new session.",
        "Use this context to personalize responses from the first turn.",
        "",
        compactContext,
      ].join("\n"),
    );
  } catch (_error) {
    // Best-effort only: do not block /new if Nexus is unavailable.
  }
};

export default handler;
