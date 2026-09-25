import { describe, expect, it } from "vitest";
import {
  ApprovalStore,
  applyCancel,
  applyDecision,
  EXPIRY_MS,
  effectiveStatus,
  newRecord,
  type DurableObjectStateLike,
} from "../src/store";

describe("effectiveStatus", () => {
  it("is expired for an unknown id", () => {
    expect(effectiveStatus(undefined, Date.now())).toBe("expired");
  });

  it("is pending within the expiry window", () => {
    const now = Date.now();
    expect(effectiveStatus(newRecord(now), now + 1000)).toBe("pending");
  });

  it("expires a pending record after 1 hour", () => {
    const now = Date.now();
    expect(effectiveStatus(newRecord(now), now + EXPIRY_MS + 1)).toBe("expired");
  });

  it("keeps a decided record's status regardless of age", () => {
    const now = Date.now();
    expect(effectiveStatus({ kind: "permission", status: "allow", createdAt: now }, now + EXPIRY_MS + 1)).toBe(
      "allow",
    );
  });
});

describe("applyDecision", () => {
  it("applies the first decision", () => {
    const now = Date.now();
    const result = applyDecision(newRecord(now), "allow", now);
    expect(result).toEqual({ record: { kind: "permission", status: "allow", createdAt: now }, applied: true, status: "allow" });
  });

  it("rejects a second decision (first answer wins)", () => {
    const now = Date.now();
    const decided = applyDecision(newRecord(now), "allow", now).record;
    const second = applyDecision(decided, "deny", now + 1);
    expect(second.applied).toBe(false);
    expect(second.status).toBe("allow");
  });

  it("rejects a decision on an expired record", () => {
    const now = Date.now();
    const result = applyDecision(newRecord(now), "allow", now + EXPIRY_MS + 1);
    expect(result).toEqual({ record: newRecord(now), applied: false, status: "expired" });
  });
});

describe("applyCancel", () => {
  it("cancels a pending record", () => {
    const now = Date.now();
    const result = applyCancel(newRecord(now), now);
    expect(result.applied).toBe(true);
    expect(result.status).toBe("cancelled");
  });

  it("is a no-op on an already-decided record", () => {
    const now = Date.now();
    const decided = applyDecision(newRecord(now), "deny", now).record;
    const result = applyCancel(decided, now);
    expect(result.applied).toBe(false);
    expect(result.status).toBe("deny");
  });
});

// --- ApprovalStore (Durable Object) integration, backed by an in-memory map -

function makeState(): DurableObjectStateLike {
  const map = new Map<string, unknown>();
  return {
    storage: {
      get: async <T>(key: string) => map.get(key) as T | undefined,
      put: async <T>(key: string, value: T) => {
        map.set(key, value);
      },
    },
  };
}

function req(url: string, init?: RequestInit) {
  return new Request(`https://do${url}`, init);
}

describe("ApprovalStore", () => {
  it("creates a pending record and reports its status", async () => {
    const store = new ApprovalStore(makeState());
    await store.fetch(req("/create", { method: "POST", body: JSON.stringify({ id: "r1" }) }));
    const res = await store.fetch(req("/status?id=r1"));
    expect(await res.json()).toEqual({ status: "pending" });
  });

  it("second decision on the same id reports it was already handled", async () => {
    const store = new ApprovalStore(makeState());
    await store.fetch(req("/create", { method: "POST", body: JSON.stringify({ id: "r1" }) }));

    const first = await store.fetch(
      req("/decide", { method: "POST", body: JSON.stringify({ id: "r1", behavior: "allow" }) }),
    );
    expect(await first.json()).toEqual({ applied: true, status: "allow" });

    const second = await store.fetch(
      req("/decide", { method: "POST", body: JSON.stringify({ id: "r1", behavior: "deny" }) }),
    );
    expect(await second.json()).toEqual({ applied: false, status: "allow" });
  });

  it("cancel is a no-op once a decision was already made", async () => {
    const store = new ApprovalStore(makeState());
    await store.fetch(req("/create", { method: "POST", body: JSON.stringify({ id: "r1" }) }));
    await store.fetch(req("/decide", { method: "POST", body: JSON.stringify({ id: "r1", behavior: "deny" }) }));

    const cancelled = await store.fetch(req("/cancel", { method: "POST", body: JSON.stringify({ id: "r1" }) }));
    expect(await cancelled.json()).toEqual({ applied: false, status: "deny" });
  });

  it("unknown routes 404", async () => {
    const store = new ApprovalStore(makeState());
    const res = await store.fetch(req("/nope"));
    expect(res.status).toBe(404);
  });
});
