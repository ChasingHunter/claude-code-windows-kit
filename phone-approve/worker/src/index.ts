import { verifyBearer, verifyWebhookSignature } from "./security";
import {
  buildApprovalMessage,
  buildTextMessage,
  sendWhatsAppMessage,
} from "./whatsapp";
import {
  isOwner,
  parseButtonReplyId,
  parseInboundEvents,
  verifyWebhookChallenge,
} from "./webhook";
import { buildQuestionListMessage, parseRowId, type QuestionInput, type QuestionRecord } from "./questions";
import { ApprovalStore } from "./store";

export { ApprovalStore };

export interface Env {
  APPROVAL_STORE: DurableObjectNamespace;
  WA_TOKEN: string;
  WA_PHONE_NUMBER_ID: string;
  WA_APP_SECRET: string;
  WA_VERIFY_TOKEN: string;
  OWNER_WA_ID: string;
  LAPTOP_SECRET: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function getStore(env: Env) {
  const id = env.APPROVAL_STORE.idFromName("global");
  return env.APPROVAL_STORE.get(id);
}

function sendMessage(env: Env, message: Parameters<typeof sendWhatsAppMessage>[0]) {
  return sendWhatsAppMessage(message, { token: env.WA_TOKEN, phoneNumberId: env.WA_PHONE_NUMBER_ID });
}

// --- POST /requests (create) -------------------------------------------------

async function handleCreatePermission(
  body: { tool_name?: string; summary?: string; cwd_name?: string },
  env: Env,
): Promise<Response> {
  const id = crypto.randomUUID();
  const toolName = body.tool_name || "tool";
  const cwdName = body.cwd_name || "project";
  const summary = body.summary || "";

  const store = getStore(env);
  await store.fetch("https://do/create", { method: "POST", body: JSON.stringify({ id }) });

  const message = buildApprovalMessage({ to: env.OWNER_WA_ID, toolName, cwdName, summary, id });
  const result = await sendMessage(env, message);

  if (!result.ok) {
    console.log("whatsapp send failed", id, result.status, result.errorCode);
    return json({ error: "whatsapp_send_failed", code: result.errorCode }, 502);
  }
  console.log("request created", id);
  return json({ id });
}

async function handleCreateQuestion(body: { questions?: QuestionInput[] }, env: Env): Promise<Response> {
  const questions = Array.isArray(body.questions) ? body.questions : [];
  if (questions.length === 0) return json({ error: "no_questions" }, 400);

  const id = crypto.randomUUID();
  const store = getStore(env);
  const res = await store.fetch("https://do/question/create", {
    method: "POST",
    body: JSON.stringify({ id, questions }),
  });
  const data = (await res.json()) as {
    activate: boolean;
    record: QuestionRecord;
    activated?: { id: string; record: QuestionRecord };
  };

  await sendActivatedQuestion(env, data.activated);

  if (data.activate) {
    const message = buildQuestionListMessage({
      to: env.OWNER_WA_ID,
      id,
      qIndex: 0,
      q: data.record.questions[0],
    });
    const result = await sendMessage(env, message);
    if (!result.ok) {
      console.log("whatsapp send failed", id, result.status, result.errorCode);
      // The laptop never gets this id, so nothing else would ever cancel it.
      const cancelRes = await store.fetch("https://do/cancel", { method: "POST", body: JSON.stringify({ id }) });
      const cancelled = (await cancelRes.json()) as { activated?: { id: string; record: QuestionRecord } };
      await sendActivatedQuestion(env, cancelled.activated);
      return json({ error: "whatsapp_send_failed", code: result.errorCode }, 502);
    }
  }

  console.log("question created", id, "activate", data.activate);
  return json({ id });
}

async function handleCreateRequest(request: Request, env: Env): Promise<Response> {
  if (!verifyBearer(request.headers.get("Authorization"), env.LAPTOP_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: {
    kind?: "permission" | "question";
    tool_name?: string;
    summary?: string;
    cwd_name?: string;
    session_id?: string;
    questions?: QuestionInput[];
  };
  try {
    body = (await request.json()) as typeof body;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  return body.kind === "question" ? handleCreateQuestion(body, env) : handleCreatePermission(body, env);
}

// --- GET /requests/:id and POST /requests/:id/cancel ------------------------

async function handleGetStatus(id: string, request: Request, env: Env): Promise<Response> {
  if (!verifyBearer(request.headers.get("Authorization"), env.LAPTOP_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }
  const store = getStore(env);
  const res = await store.fetch(`https://do/status?id=${encodeURIComponent(id)}`);
  const data = (await res.json()) as { status: string; answers?: Record<string, string> };
  return json(data);
}

async function sendActivatedQuestion(env: Env, activated: { id: string; record: QuestionRecord } | undefined) {
  if (!activated) return;
  const message = buildQuestionListMessage({
    to: env.OWNER_WA_ID,
    id: activated.id,
    qIndex: 0,
    q: activated.record.questions[0],
  });
  await sendMessage(env, message).catch(() => {});
}

async function handleCancel(id: string, request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (!verifyBearer(request.headers.get("Authorization"), env.LAPTOP_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }
  const store = getStore(env);
  const res = await store.fetch("https://do/cancel", { method: "POST", body: JSON.stringify({ id }) });
  const data = (await res.json()) as {
    applied: boolean;
    status: string;
    activated?: { id: string; record: QuestionRecord };
  };
  console.log("cancel", id, data.applied);

  if (data.applied) {
    // Best-effort courtesy message; failure here must never affect the
    // cancel response the laptop is waiting on.
    ctx.waitUntil(sendMessage(env, buildTextMessage(env.OWNER_WA_ID, "⏹ handled on laptop")).catch(() => {}));
    ctx.waitUntil(sendActivatedQuestion(env, data.activated));
  }
  return json({ status: data.status });
}

// --- Webhook -----------------------------------------------------------------

function handleWebhookVerify(request: Request, env: Env): Response {
  const url = new URL(request.url);
  const challenge = verifyWebhookChallenge(url.searchParams, env.WA_VERIFY_TOKEN);
  if (challenge === null) return new Response("forbidden", { status: 403 });
  return new Response(challenge, { status: 200 });
}

/** Applies an answer (from a row tap or a free-text reply) and sends
 * whatever comes next: the next question in the same call, a completion
 * note, and/or the first question of a newly-activated queued call. */
async function handleQuestionAnswer(
  env: Env,
  ctx: ExecutionContext,
  store: ReturnType<typeof getStore>,
  args: { id: string; qIndex: number; optIndex?: number; freeText?: string },
) {
  const res = await store.fetch("https://do/question/answer", { method: "POST", body: JSON.stringify(args) });
  const data = (await res.json()) as {
    applied: boolean;
    status?: string;
    currentIndex?: number;
    questions?: QuestionInput[];
    activated?: { id: string; record: QuestionRecord };
  };
  console.log("question answer", args.id, args.qIndex, data.applied);

  if (!data.applied) {
    ctx.waitUntil(sendMessage(env, buildTextMessage(env.OWNER_WA_ID, "Already handled")).catch(() => {}));
    return;
  }

  if (data.status === "pending" && data.questions && typeof data.currentIndex === "number") {
    const message = buildQuestionListMessage({
      to: env.OWNER_WA_ID,
      id: args.id,
      qIndex: data.currentIndex,
      q: data.questions[data.currentIndex],
    });
    ctx.waitUntil(sendMessage(env, message).catch(() => {}));
  } else if (data.status === "answered") {
    ctx.waitUntil(sendMessage(env, buildTextMessage(env.OWNER_WA_ID, "✅ Got it, thanks!")).catch(() => {}));
  }
  ctx.waitUntil(sendActivatedQuestion(env, data.activated));
}

async function handleOtherRowTap(env: Env, ctx: ExecutionContext, store: ReturnType<typeof getStore>, id: string, qIndex: number) {
  const res = await store.fetch(`https://do/question/record?id=${encodeURIComponent(id)}`);
  const data = (await res.json()) as { record: QuestionRecord | null };
  const stillCurrent = data.record?.status === "pending" && data.record.currentIndex === qIndex;
  const reply = stillCurrent
    ? `Type your answer for: ${data.record!.questions[qIndex].question}`
    : "Already handled";
  ctx.waitUntil(sendMessage(env, buildTextMessage(env.OWNER_WA_ID, reply)).catch(() => {}));
}

async function handleWebhookEvent(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const rawBody = await request.text();
  const signatureOk = await verifyWebhookSignature(
    rawBody,
    request.headers.get("X-Hub-Signature-256"),
    env.WA_APP_SECRET,
  );
  if (!signatureOk) return new Response("invalid signature", { status: 401 });

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    // Malformed body from a verified sender shouldn't happen; ack anyway so
    // Meta doesn't retry a payload we'll never be able to parse.
    return new Response("ok", { status: 200 });
  }

  const events = parseInboundEvents(payload);
  const store = getStore(env);

  for (const event of events) {
    if (!isOwner(event.from, env.OWNER_WA_ID)) continue;

    if (event.kind === "button_reply" && event.buttonReplyId) {
      const approval = parseButtonReplyId(event.buttonReplyId);
      if (approval) {
        const res = await store.fetch("https://do/decide", {
          method: "POST",
          body: JSON.stringify({ id: approval.id, behavior: approval.behavior }),
        });
        const data = (await res.json()) as { applied: boolean; status: string };
        console.log("decision", approval.id, approval.behavior, data.applied);

        const reply = !data.applied
          ? "Already handled"
          : approval.behavior === "allow"
            ? "✅ Approved"
            : "❌ Denied";
        ctx.waitUntil(sendMessage(env, buildTextMessage(env.OWNER_WA_ID, reply)).catch(() => {}));
        continue;
      }

      const row = parseRowId(event.buttonReplyId);
      if (row) {
        if (row.opt === "other") {
          await handleOtherRowTap(env, ctx, store, row.id, row.qIndex);
        } else {
          await handleQuestionAnswer(env, ctx, store, { id: row.id, qIndex: row.qIndex, optIndex: row.opt });
        }
      }
    } else if (event.kind === "text") {
      const activeRes = await store.fetch("https://do/question/active");
      const active = (await activeRes.json()) as {
        activeId: string | null;
        activated?: { id: string; record: QuestionRecord };
      };

      if (active.activated) {
        // Its question was never shown, so this text can't be an answer to it.
        ctx.waitUntil(sendActivatedQuestion(env, active.activated));
        continue;
      }

      if (active.activeId) {
        const recordRes = await store.fetch(`https://do/question/record?id=${encodeURIComponent(active.activeId)}`);
        const recordData = (await recordRes.json()) as { record: QuestionRecord | null };
        if (recordData.record && recordData.record.status === "pending") {
          await handleQuestionAnswer(env, ctx, store, {
            id: active.activeId,
            qIndex: recordData.record.currentIndex,
            freeText: event.text ?? "",
          });
          continue;
        }
      }

      ctx.waitUntil(
        sendMessage(
          env,
          buildTextMessage(
            env.OWNER_WA_ID,
            "👋 phone-approve is listening. Approvals will arrive here for 24h.",
          ),
        ).catch(() => {}),
      );
    }
  }

  return new Response("ok", { status: 200 });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/requests") {
      return handleCreateRequest(request, env);
    }

    const statusMatch = /^\/requests\/([^/]+)$/.exec(url.pathname);
    if (request.method === "GET" && statusMatch) {
      return handleGetStatus(statusMatch[1], request, env);
    }

    const cancelMatch = /^\/requests\/([^/]+)\/cancel$/.exec(url.pathname);
    if (request.method === "POST" && cancelMatch) {
      return handleCancel(cancelMatch[1], request, env, ctx);
    }

    if (request.method === "GET" && url.pathname === "/webhook") {
      return handleWebhookVerify(request, env);
    }

    if (request.method === "POST" && url.pathname === "/webhook") {
      return handleWebhookEvent(request, env, ctx);
    }

    return json({ error: "not found" }, 404);
  },
};
