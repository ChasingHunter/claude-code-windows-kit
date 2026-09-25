import { describe, expect, it } from "vitest";
import { isOwner, parseButtonReplyId, parseInboundEvents, verifyWebhookChallenge } from "../src/webhook";

describe("verifyWebhookChallenge", () => {
  it("echoes the challenge when mode and token match", () => {
    const q = new URLSearchParams({ "hub.mode": "subscribe", "hub.verify_token": "tok", "hub.challenge": "12345" });
    expect(verifyWebhookChallenge(q, "tok")).toBe("12345");
  });

  it("rejects a wrong verify token", () => {
    const q = new URLSearchParams({ "hub.mode": "subscribe", "hub.verify_token": "wrong", "hub.challenge": "12345" });
    expect(verifyWebhookChallenge(q, "tok")).toBeNull();
  });

  it("rejects a mode other than subscribe", () => {
    const q = new URLSearchParams({ "hub.mode": "unsubscribe", "hub.verify_token": "tok", "hub.challenge": "12345" });
    expect(verifyWebhookChallenge(q, "tok")).toBeNull();
  });

  it("rejects a missing challenge", () => {
    const q = new URLSearchParams({ "hub.mode": "subscribe", "hub.verify_token": "tok" });
    expect(verifyWebhookChallenge(q, "tok")).toBeNull();
  });
});

function textPayload(from: string, body: string) {
  return {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "1",
        changes: [
          {
            value: {
              messaging_product: "whatsapp",
              messages: [{ from, id: "wamid.1", timestamp: "1", type: "text", text: { body } }],
            },
          },
        ],
      },
    ],
  };
}

function buttonReplyPayload(from: string, buttonReplyId: string) {
  return {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "1",
        changes: [
          {
            value: {
              messaging_product: "whatsapp",
              messages: [
                {
                  from,
                  id: "wamid.2",
                  timestamp: "1",
                  type: "interactive",
                  interactive: { type: "button_reply", button_reply: { id: buttonReplyId, title: "Approve" } },
                },
              ],
            },
          },
        ],
      },
    ],
  };
}

function listReplyPayload(from: string, listReplyId: string) {
  return {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "1",
        changes: [
          {
            value: {
              messaging_product: "whatsapp",
              messages: [
                {
                  from,
                  id: "wamid.3",
                  timestamp: "1",
                  type: "interactive",
                  interactive: { type: "list_reply", list_reply: { id: listReplyId, title: "Option" } },
                },
              ],
            },
          },
        ],
      },
    ],
  };
}

describe("parseInboundEvents", () => {
  it("parses a text message", () => {
    const events = parseInboundEvents(textPayload("16505551234", "hi"));
    expect(events).toEqual([{ from: "16505551234", kind: "text", text: "hi" }]);
  });

  it("parses a button reply", () => {
    const events = parseInboundEvents(buttonReplyPayload("16505551234", "allow:abc-123"));
    expect(events).toEqual([{ from: "16505551234", kind: "button_reply", buttonReplyId: "allow:abc-123" }]);
  });

  it("parses a list reply (AskUserQuestion row tap) the same way as a button reply", () => {
    const events = parseInboundEvents(listReplyPayload("16505551234", "q:abc-123:0:1"));
    expect(events).toEqual([{ from: "16505551234", kind: "button_reply", buttonReplyId: "q:abc-123:0:1" }]);
  });

  it("returns no events for malformed payloads", () => {
    expect(parseInboundEvents(null)).toEqual([]);
    expect(parseInboundEvents({})).toEqual([]);
    expect(parseInboundEvents({ entry: "not-an-array" })).toEqual([]);
    expect(parseInboundEvents({ entry: [{ changes: [{ value: {} }] }] })).toEqual([]);
  });
});

describe("isOwner", () => {
  it("matches only the configured owner id", () => {
    expect(isOwner("16505551234", "16505551234")).toBe(true);
    expect(isOwner("19998887777", "16505551234")).toBe(false);
  });
});

describe("parseButtonReplyId", () => {
  it("parses allow:<id>", () => {
    expect(parseButtonReplyId("allow:abc-123")).toEqual({ behavior: "allow", id: "abc-123" });
  });

  it("parses deny:<id>", () => {
    expect(parseButtonReplyId("deny:abc-123")).toEqual({ behavior: "deny", id: "abc-123" });
  });

  it("returns null for unrelated ids (e.g. a question row id)", () => {
    expect(parseButtonReplyId("q:abc-123:0:1")).toBeNull();
  });
});
