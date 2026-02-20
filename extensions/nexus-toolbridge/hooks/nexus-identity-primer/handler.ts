function normalizeBaseUrl(input: string | undefined | null): string {
  const raw = String(input ?? "").trim();
  if (!raw) return "";
  
  // Remove trailing slashes
  let url = raw.replace(/\/+$/, "");
  
  // Ensure protocol is present
  if (!/^https?:\/\//i.test(url)) {
    url = "https://" + url;
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
