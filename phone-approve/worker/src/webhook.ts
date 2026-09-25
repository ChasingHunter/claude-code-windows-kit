// Parsing of Meta's webhook GET verification and POST event payloads.
// Pure functions only — no fetch, no storage — so they're trivial to unit test.

export interface InboundEvent {
  from: string;
  kind: "text" | "button_reply" | "other";
  text?: string;
  buttonReplyId?: string;
}

/** Verifies the GET /webhook challenge query params per Meta's webhook setup
 * flow: hub.mode must be "subscribe" and hub.verify_token must match. Returns
 * the challenge string to echo back, or null if verification fails. */
export function verifyWebhookChallenge(
  query: URLSearchParams,
  verifyToken: string,
): string | null {
  const mode = query.get("hub.mode");
  const token = query.get("hub.verify_token");
  const challenge = query.get("hub.challenge");
  if (mode === "subscribe" && token === verifyToken && challenge != null) {
    return challenge;
  }
  return null;
}

/** Extracts the inbound message events from a webhook POST body. Malformed
 * or unrecognized payloads simply yield no events rather than throwing. */
export function parseInboundEvents(payload: unknown): InboundEvent[] {
  const events: InboundEvent[] = [];
  if (!payload || typeof payload !== "object") return events;

  const entries = (payload as { entry?: unknown }).entry;
  if (!Array.isArray(entries)) return events;

  for (const entry of entries) {
    const changes = (entry as { changes?: unknown })?.changes;
    if (!Array.isArray(changes)) continue;

    for (const change of changes) {
      const messages = (change as { value?: { messages?: unknown } })?.value?.messages;
      if (!Array.isArray(messages)) continue;

      for (const msg of messages) {
        const from = (msg as { from?: unknown })?.from;
        if (typeof from !== "string") continue;

        const type = (msg as { type?: unknown })?.type;
        if (type === "text") {
          const body = (msg as { text?: { body?: unknown } })?.text?.body;
          events.push({ from, kind: "text", text: typeof body === "string" ? body : "" });
        } else if (type === "interactive") {
          // Outbound "button" messages come back as interactive.button_reply;
          // outbound "list" messages (used for AskUserQuestion) come back as
          // interactive.list_reply. Both carry the same {id, title} shape, so
          // both normalize to the same `buttonReplyId` field here — callers
          // distinguish allow:/deny: (button) from q:... (list row) ids.
          const interactive = (
            msg as {
              interactive?: {
                type?: unknown;
                button_reply?: { id?: unknown };
                list_reply?: { id?: unknown };
              };
            }
          )?.interactive;
          const replyId =
            interactive?.type === "button_reply"
              ? interactive.button_reply?.id
              : interactive?.type === "list_reply"
                ? interactive.list_reply?.id
                : undefined;
          if (typeof replyId === "string") {
            events.push({ from, kind: "button_reply", buttonReplyId: replyId });
          } else {
            events.push({ from, kind: "other" });
          }
        } else {
          events.push({ from, kind: "other" });
        }
      }
    }
  }
  return events;
}

export function isOwner(from: string, ownerWaId: string): boolean {
  return from === ownerWaId;
}

/** Parses a `allow:<id>` / `deny:<id>` button reply id. Returns null for
 * anything else so callers can ignore unrecognized button ids safely. */
export function parseButtonReplyId(buttonReplyId: string): { behavior: "allow" | "deny"; id: string } | null {
  const match = /^(allow|deny):(.+)$/.exec(buttonReplyId);
  if (!match) return null;
  return { behavior: match[1] as "allow" | "deny", id: match[2] };
}
