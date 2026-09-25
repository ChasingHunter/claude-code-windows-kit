// WhatsApp Cloud API message building + sending.
//
// Confirmed against Meta's Cloud API docs (2026-09-25): current stable Graph
// API version is v26.0. POST https://graph.facebook.com/v{VERSION}/{phone-number-id}/messages
// with Authorization: Bearer <permanent System User token>, Content-Type: application/json.
//
// Interactive "button" messages: body text max 1024 chars, footer max 60
// chars, max 3 reply buttons, button title max 20 chars, button id max 256
// chars. The inbound webhook button-reply payload shape
// (interactive.button_reply.{id,title}) is the long-stable, widely
// documented Cloud API shape; Meta's own docs page for that specific example
// could not be fetched in full during review, so this one shape is
// cross-checked against the send-side "reply.id"/"reply.title" naming rather
// than a literal doc quote — flagged in the PR/report as a soft
// confirmation, not a hard one.

export const GRAPH_API_VERSION = "v26.0";

export const BODY_MAX_LEN = 1024;
export const FOOTER_MAX_LEN = 60;
export const BUTTON_TITLE_MAX_LEN = 20;

export interface ReplyButton {
  id: string;
  title: string;
}

export interface InteractiveButtonMessage {
  messaging_product: "whatsapp";
  recipient_type: "individual";
  to: string;
  type: "interactive";
  interactive: {
    type: "button";
    body: { text: string };
    footer: { text: string };
    action: { buttons: Array<{ type: "reply"; reply: ReplyButton }> };
  };
}

export interface TextMessage {
  messaging_product: "whatsapp";
  to: string;
  type: "text";
  text: { body: string };
}

// AskUserQuestion's list messages are built in questions.ts (a distinct
// domain from approval buttons) but sent through the same Graph API call.
export type OutboundMessage = InteractiveButtonMessage | TextMessage | import("./questions").ListMessage;

/** Truncates `summary` (never the fixed prefix) so `prefix + summary` stays
 * within `maxLen` characters, appending an ellipsis when cut. */
export function truncateBody(prefix: string, summary: string, maxLen = BODY_MAX_LEN): string {
  const full = prefix + summary;
  if (full.length <= maxLen) return full;
  const ellipsis = "…";
  const room = maxLen - prefix.length - ellipsis.length;
  if (room <= 0) {
    // Prefix alone doesn't fit either; hard-truncate the whole thing.
    return full.slice(0, Math.max(0, maxLen));
  }
  return prefix + summary.slice(0, room) + ellipsis;
}

export function shortCodeFor(id: string): string {
  return id.split("-")[0] ?? id.slice(0, 8);
}

/** Builds the interactive Approve/Deny message body sent to the owner. */
export function buildApprovalMessage(params: {
  to: string;
  toolName: string;
  cwdName: string;
  summary: string;
  id: string;
}): InteractiveButtonMessage {
  const { to, toolName, cwdName, summary, id } = params;
  const prefix = `🔐 Claude wants to run *${toolName}* in *${cwdName}*:\n\n`;
  const body = truncateBody(prefix, summary, BODY_MAX_LEN);
  const footer = `Code: ${shortCodeFor(id)}`.slice(0, FOOTER_MAX_LEN);

  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to,
    type: "interactive",
    interactive: {
      type: "button",
      body: { text: body },
      footer: { text: footer },
      action: {
        buttons: [
          { type: "reply", reply: { id: `allow:${id}`, title: "Approve" } },
          { type: "reply", reply: { id: `deny:${id}`, title: "Deny" } },
        ],
      },
    },
  };
}

export function buildTextMessage(to: string, body: string): TextMessage {
  return { messaging_product: "whatsapp", to, type: "text", text: { body } };
}

export interface WhatsAppSendResult {
  ok: boolean;
  status: number;
  errorCode?: number;
  errorMessage?: string;
}

/** Sends a message via the Graph API. Never throws — network/API failures
 * come back as `{ ok: false, ... }` so callers can fall back cleanly. */
export async function sendWhatsAppMessage(
  message: OutboundMessage,
  opts: { token: string; phoneNumberId: string; fetchImpl?: typeof fetch },
): Promise<WhatsAppSendResult> {
  const doFetch = opts.fetchImpl ?? fetch;
  const url = `https://graph.facebook.com/${GRAPH_API_VERSION}/${opts.phoneNumberId}/messages`;
  try {
    const res = await doFetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${opts.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(message),
    });
    if (res.ok) return { ok: true, status: res.status };

    let errorCode: number | undefined;
    let errorMessage: string | undefined;
    try {
      const data = (await res.json()) as { error?: { code?: number; message?: string } };
      errorCode = data?.error?.code;
      errorMessage = data?.error?.message;
    } catch {
      // Non-JSON error body — fall through with status only.
    }
    return { ok: false, status: res.status, errorCode, errorMessage };
  } catch (err) {
    return { ok: false, status: 0, errorMessage: err instanceof Error ? err.message : String(err) };
  }
}
