import { describe, expect, it, vi } from "vitest";
import {
  BODY_MAX_LEN,
  buildApprovalMessage,
  buildTextMessage,
  sendWhatsAppMessage,
  shortCodeFor,
  truncateBody,
} from "../src/whatsapp";

describe("truncateBody", () => {
  it("returns prefix + summary unchanged when it fits", () => {
    expect(truncateBody("prefix: ", "short", 100)).toBe("prefix: short");
  });

  it("truncates the summary, not the prefix, when too long", () => {
    const prefix = "prefix: ";
    const summary = "x".repeat(50);
    const result = truncateBody(prefix, summary, 20);
    expect(result.length).toBeLessThanOrEqual(20);
    expect(result.startsWith(prefix)).toBe(true);
    expect(result.endsWith("…")).toBe(true);
  });

  it("hard-truncates when even the prefix alone doesn't fit", () => {
    const result = truncateBody("a very long prefix that alone exceeds the budget", "summary", 10);
    expect(result.length).toBeLessThanOrEqual(10);
  });
});

describe("buildApprovalMessage", () => {
  it("keeps the whole body under 1024 chars for a huge summary", () => {
    const message = buildApprovalMessage({
      to: "15550001111",
      toolName: "Bash",
      cwdName: "localvert",
      summary: "x".repeat(5000),
      id: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    });
    expect(message.interactive.body.text.length).toBeLessThanOrEqual(BODY_MAX_LEN);
  });

  it("builds Approve/Deny buttons keyed by the full id", () => {
    const id = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
    const message = buildApprovalMessage({ to: "1", toolName: "Bash", cwdName: "proj", summary: "ls", id });
    expect(message.interactive.action.buttons).toEqual([
      { type: "reply", reply: { id: `allow:${id}`, title: "Approve" } },
      { type: "reply", reply: { id: `deny:${id}`, title: "Deny" } },
    ]);
  });

  it("puts the short code in the footer, within 60 chars", () => {
    const id = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
    const message = buildApprovalMessage({ to: "1", toolName: "Bash", cwdName: "proj", summary: "ls", id });
    expect(message.interactive.footer.text).toBe(`Code: ${shortCodeFor(id)}`);
    expect(message.interactive.footer.text.length).toBeLessThanOrEqual(60);
  });

  it("includes the tool name and cwd in the body", () => {
    const message = buildApprovalMessage({
      to: "1",
      toolName: "Edit",
      cwdName: "my-repo",
      summary: "src/index.ts",
      id: "abcd1234-0000-0000-0000-000000000000",
    });
    expect(message.interactive.body.text).toContain("Edit");
    expect(message.interactive.body.text).toContain("my-repo");
    expect(message.interactive.body.text).toContain("src/index.ts");
  });
});

describe("shortCodeFor", () => {
  it("takes the first hyphen-delimited group of a uuid", () => {
    expect(shortCodeFor("3fa85f64-5717-4562-b3fc-2c963f66afa6")).toBe("3fa85f64");
  });
});

describe("buildTextMessage", () => {
  it("builds a plain text message payload", () => {
    expect(buildTextMessage("15550001111", "hi")).toEqual({
      messaging_product: "whatsapp",
      to: "15550001111",
      type: "text",
      text: { body: "hi" },
    });
  });
});

describe("sendWhatsAppMessage", () => {
  it("returns ok on a 200 response", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
    const result = await sendWhatsAppMessage(buildTextMessage("1", "hi"), {
      token: "tok",
      phoneNumberId: "123",
      fetchImpl,
    });
    expect(result).toEqual({ ok: true, status: 200 });
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://graph.facebook.com/v26.0/123/messages",
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({ Authorization: "Bearer tok" }),
      }),
    );
  });

  it("surfaces Meta's error code on failure, e.g. 131047 (24h window closed)", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: { code: 131047, message: "Re-engagement message" } }), { status: 400 }),
    );
    const result = await sendWhatsAppMessage(buildTextMessage("1", "hi"), {
      token: "tok",
      phoneNumberId: "123",
      fetchImpl,
    });
    expect(result.ok).toBe(false);
    expect(result.errorCode).toBe(131047);
  });

  it("never throws when the network call itself fails", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    const result = await sendWhatsAppMessage(buildTextMessage("1", "hi"), {
      token: "tok",
      phoneNumberId: "123",
      fetchImpl,
    });
    expect(result.ok).toBe(false);
  });
});
