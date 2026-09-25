// Pure(ish) auth helpers. No file/command text ever passes through here.

/** Constant-time-ish comparison of two equal-shape secrets. Lengths differing
 * is not hidden (this matches Node's own crypto.timingSafeEqual behavior,
 * which throws on length mismatch) but the *content* comparison is
 * branchless once lengths match. */
function timingSafeEqualString(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/** Verifies `Authorization: Bearer <secret>` against the configured secret. */
export function verifyBearer(authHeader: string | null | undefined, secret: string): boolean {
  if (!authHeader || !secret) return false;
  const prefix = "Bearer ";
  if (!authHeader.startsWith(prefix)) return false;
  const token = authHeader.slice(prefix.length);
  return timingSafeEqualString(token, secret);
}

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Computes the hex HMAC-SHA256 of `body` keyed by `secret`, using WebCrypto
 * (available in both the Workers runtime and modern Node, so this is
 * testable under plain vitest with no Workers-specific runtime). */
export async function hmacSha256Hex(body: string, secret: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return toHex(sig);
}

/** Verifies Meta's `X-Hub-Signature-256: sha256=<hex>` header against the
 * RAW request body, using the WhatsApp app secret. */
export async function verifyWebhookSignature(
  rawBody: string,
  signatureHeader: string | null | undefined,
  appSecret: string,
): Promise<boolean> {
  if (!signatureHeader || !appSecret) return false;
  const prefix = "sha256=";
  if (!signatureHeader.startsWith(prefix)) return false;
  const provided = signatureHeader.slice(prefix.length).toLowerCase();
  const expected = await hmacSha256Hex(rawBody, appSecret);
  return timingSafeEqualString(provided, expected);
}
