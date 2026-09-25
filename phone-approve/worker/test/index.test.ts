import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { ApprovalStore, type Env } from "../src/index";
import { hmacSha256Hex } from "../src/security";

const LAPTOP_SECRET = "laptop-secret";
const WA_APP_SECRET = "app-secret";
const WA_VERIFY_TOKEN = "verify-token";
const OWNER_WA_ID = "16505551234";

function makeState() {
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

/** Wraps a real ApprovalStore instance behind the (url, init) => Response
 * calling convention a real DurableObjectStub exposes, so index.ts's
 * `store.fetch("https://do/...", init)` calls work exactly as they would in
 * production, backed by an in-memory map instead of real DO storage. */
function makeStoreStub() {
  const store = new ApprovalStore(makeState());
  return { fetch: (url: string, init?: RequestInit) => store.fetch(new Request(url, init)) };
}

function makeEnv(): Env {
  // A real DurableObjectNamespace.get(id) returns a stub bound to the SAME
  // persistent instance every time for a given id — build the stub once and
  // hand back that same instance, or state would reset on every call.
  const stub = makeStoreStub();
  return {
    APPROVAL_STORE: {
      idFromName: () => "global",
      get: () => stub,
    } as unknown as Env["APPROVAL_STORE"],
    WA_TOKEN: "wa-token",
    WA_PHONE_NUMBER_ID: "123456",
    WA_APP_SECRET,
    WA_VERIFY_TOKEN,
    OWNER_WA_ID,
    LAPTOP_SECRET,
  };
}

function makeCtx(): ExecutionContext {
  const waits: Promise<unknown>[] = [];
  return {
    waitUntil: (p: Promise<unknown>) => {
      waits.push(p);
    },
    passThroughOnException: () => {},
    props: {},
    // Exposed for tests to await background sends before asserting on them.
    // @ts-expect-error test-only helper
    __waits: waits,
  };
}

async function flush(ctx: ExecutionContext) {
  // @ts-expect-error test-only helper
  await Promise.all(ctx.__waits);
}

let sentMessages: Array<{ url: string; body: unknown }> = [];

beforeEach(() => {
  sentMessages = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init?: RequestInit) => {
      sentMessages.push({ url, body: init?.body ? JSON.parse(init.body as string) : undefined });
      return new Response("{}", { status: 200 });
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function call(env: Env, ctx: ExecutionContext, path: string, init?: RequestInit) {
  return worker.fetch(new Request(`https://worker${path}`, init), env, ctx);
}

describe("POST /requests auth", () => {
  it("401s without a bearer token", async () => {
    const env = makeEnv();
    const res = await call(env, makeCtx(), "/requests", { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
  });

  it("401s with the wrong bearer token", async () => {
    const env = makeEnv();
    const res = await call(env, makeCtx(), "/requests", {
      method: "POST",
      headers: { Authorization: "Bearer wrong" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });
});

describe("POST /requests (permission)", () => {
  it("creates a request and sends a WhatsApp button message", async () => {
    const env = makeEnv();
    const ctx = makeCtx();
    const res = await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify({ tool_name: "Bash", summary: "ls -la", cwd_name: "localvert" }),
    });
    expect(res.status).toBe(200);
    const { id } = (await res.json()) as { id: string };
    expect(id).toBeTruthy();
    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].url).toContain("/messages");

    const statusRes = await call(env, ctx, `/requests/${id}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect(await statusRes.json()).toEqual({ status: "pending" });
  });

  it("returns 502 with Meta's error code when the send fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ error: { code: 131047 } }), { status: 400 })),
    );
    const env = makeEnv();
    const res = await call(env, makeCtx(), "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ tool_name: "Bash", summary: "ls" }),
    });
    expect(res.status).toBe(502);
    expect((await res.json()) as { code: number }).toMatchObject({ code: 131047 });
  });
});

describe("GET /webhook verification", () => {
  it("echoes the challenge for a correct verify token", async () => {
    const env = makeEnv();
    const res = await call(
      env,
      makeCtx(),
      `/webhook?hub.mode=subscribe&hub.verify_token=${WA_VERIFY_TOKEN}&hub.challenge=999`,
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("999");
  });

  it("403s for a wrong verify token", async () => {
    const env = makeEnv();
    const res = await call(env, makeCtx(), "/webhook?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=999");
    expect(res.status).toBe(403);
  });
});

async function postWebhook(env: Env, ctx: ExecutionContext, payload: unknown) {
  const body = JSON.stringify(payload);
  const signature = `sha256=${await hmacSha256Hex(body, WA_APP_SECRET)}`;
  return call(env, ctx, "/webhook", {
    method: "POST",
    headers: { "X-Hub-Signature-256": signature },
    body,
  });
}

function messagePayload(from: string, message: Record<string, unknown>) {
  return {
    object: "whatsapp_business_account",
    entry: [{ id: "1", changes: [{ value: { messaging_product: "whatsapp", messages: [{ from, ...message }] } }] }],
  };
}

describe("POST /webhook signature", () => {
  it("401s an unsigned request", async () => {
    const env = makeEnv();
    const res = await call(env, makeCtx(), "/webhook", { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
  });

  it("401s a request signed with the wrong secret", async () => {
    const env = makeEnv();
    const body = "{}";
    const badSig = `sha256=${await hmacSha256Hex(body, "wrong-secret")}`;
    const res = await call(env, makeCtx(), "/webhook", {
      method: "POST",
      headers: { "X-Hub-Signature-256": badSig },
      body,
    });
    expect(res.status).toBe(401);
  });
});

describe("POST /webhook button replies", () => {
  it("sets the decision once, and reports 'Already handled' on a second tap", async () => {
    const env = makeEnv();
    const ctx = makeCtx();
    const createRes = await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ tool_name: "Bash", summary: "ls" }),
    });
    const { id } = (await createRes.json()) as { id: string };
    sentMessages = [];

    const first = await postWebhook(
      env,
      ctx,
      messagePayload(OWNER_WA_ID, {
        type: "interactive",
        interactive: { type: "button_reply", button_reply: { id: `allow:${id}` } },
      }),
    );
    expect(first.status).toBe(200);
    await flush(ctx);
    expect(sentMessages).toHaveLength(1);
    expect(JSON.stringify(sentMessages[0].body)).toContain("Approved");

    sentMessages = [];
    const second = await postWebhook(
      env,
      ctx,
      messagePayload(OWNER_WA_ID, {
        type: "interactive",
        interactive: { type: "button_reply", button_reply: { id: `allow:${id}` } },
      }),
    );
    expect(second.status).toBe(200);
    await flush(ctx);
    expect(JSON.stringify(sentMessages[0].body)).toContain("Already handled");

    const statusRes = await call(env, ctx, `/requests/${id}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect(await statusRes.json()).toEqual({ status: "allow" });
  });

  it("ignores a button reply from someone other than the owner", async () => {
    const env = makeEnv();
    const ctx = makeCtx();
    const createRes = await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ tool_name: "Bash", summary: "ls" }),
    });
    const { id } = (await createRes.json()) as { id: string };
    sentMessages = [];

    await postWebhook(
      env,
      ctx,
      messagePayload("19998887777", {
        type: "interactive",
        interactive: { type: "button_reply", button_reply: { id: `allow:${id}` } },
      }),
    );
    await flush(ctx);
    expect(sentMessages).toHaveLength(0);

    const statusRes = await call(env, ctx, `/requests/${id}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect(await statusRes.json()).toEqual({ status: "pending" });
  });
});

describe("AskUserQuestion flow", () => {
  const question = {
    question: "Which approach?",
    header: "Approach",
    options: [{ label: "A" }, { label: "B" }],
  };

  it("sends the first question immediately, queues a second, and activates it once the first is answered", async () => {
    const env = makeEnv();
    const ctx = makeCtx();

    const r1 = await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ kind: "question", questions: [question] }),
    });
    const { id: id1 } = (await r1.json()) as { id: string };
    expect(sentMessages).toHaveLength(1);
    expect(JSON.stringify(sentMessages[0].body)).toContain("Which approach?");

    const secondQuestion = { ...question, question: "Which database?" };
    sentMessages = [];
    const r2 = await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ kind: "question", questions: [secondQuestion] }),
    });
    const { id: id2 } = (await r2.json()) as { id: string };
    // Queued: nothing sent yet for the second question.
    expect(sentMessages).toHaveLength(0);

    // Answer the first question via a row tap.
    sentMessages = [];
    await postWebhook(
      env,
      ctx,
      messagePayload(OWNER_WA_ID, {
        type: "interactive",
        interactive: { type: "list_reply", list_reply: { id: `q:${id1}:0:0` } },
      }),
    );
    await flush(ctx);

    const statusRes1 = await call(env, ctx, `/requests/${id1}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect(await statusRes1.json()).toEqual({ status: "answered", answers: { "Which approach?": "A" } });

    // The queued second question should now have been activated and sent.
    const bodies = sentMessages.map((m) => JSON.stringify(m.body));
    expect(bodies.some((b) => b.includes("Which database?"))).toBe(true);

    const statusRes2 = await call(env, ctx, `/requests/${id2}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect((await statusRes2.json()) as { status: string }).toEqual({ status: "pending" });
  });

  it("accepts a free-text reply as the answer to the active question", async () => {
    const env = makeEnv();
    const ctx = makeCtx();
    await call(env, ctx, "/requests", {
      method: "POST",
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
      body: JSON.stringify({ kind: "question", questions: [question] }),
    });
    // grab the id from the sent list message's row id
    const rowId = (sentMessages[0].body as any).interactive.action.sections[0].rows[0].id as string;
    const id = rowId.split(":")[1];

    sentMessages = [];
    await postWebhook(env, ctx, messagePayload(OWNER_WA_ID, { type: "text", text: { body: "my own answer" } }));
    await flush(ctx);

    const statusRes = await call(env, ctx, `/requests/${id}`, {
      headers: { Authorization: `Bearer ${LAPTOP_SECRET}` },
    });
    expect(await statusRes.json()).toEqual({ status: "answered", answers: { "Which approach?": "my own answer" } });
  });

  it("falls back to the canned listening reply when no question is active", async () => {
    const env = makeEnv();
    const ctx = makeCtx();
    await postWebhook(env, ctx, messagePayload(OWNER_WA_ID, { type: "text", text: { body: "hi" } }));
    await flush(ctx);
    expect(JSON.stringify(sentMessages[0].body)).toContain("listening");
  });
});
