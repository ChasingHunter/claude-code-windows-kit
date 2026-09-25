// Durable Object holding approval + AskUserQuestion state. Records only ever
// carry ids, statuses, timestamps, and — for the question flow only — the
// question/option text and the labels the owner picked, since that's the
// minimum needed to render sequential WhatsApp list messages and resolve
// stale taps. Tool commands, file paths, and Bash summaries are NEVER
// persisted here: those are built and sent straight through to WhatsApp by
// index.ts and never touch storage.

import {
  activateNext,
  applyAnswer,
  cancelQuestion,
  enqueueOrActivate,
  newQuestionRecord,
  parseFreeTextAnswer,
  questionEffectiveStatus,
  type QuestionInput,
  type QuestionRecord,
} from "./questions";

export type ApprovalStatus = "pending" | "allow" | "deny" | "cancelled" | "expired";

export interface ApprovalRecord {
  kind: "permission";
  status: ApprovalStatus;
  createdAt: number;
}

export type AnyRecord = ApprovalRecord | QuestionRecord;

export const EXPIRY_MS = 60 * 60 * 1000; // 1 hour

/** Pure: resolves the *effective* status of a permission record at time
 * `now`, lazily expiring stale pending records rather than needing an
 * alarm. */
export function effectiveStatus(record: ApprovalRecord | undefined, now: number): ApprovalStatus {
  if (!record) return "expired";
  if (record.status === "pending" && now - record.createdAt > EXPIRY_MS) return "expired";
  return record.status;
}

/** Pure: applies an allow/deny decision. First decision wins — once a
 * record is no longer pending (already decided, cancelled, or expired),
 * further attempts are rejected and the caller should tell Meta
 * "already handled" rather than silently overwriting the outcome. */
export function applyDecision(
  record: ApprovalRecord | undefined,
  behavior: "allow" | "deny",
  now: number,
): { record: ApprovalRecord | undefined; applied: boolean; status: ApprovalStatus } {
  const current = effectiveStatus(record, now);
  if (current !== "pending" || !record) {
    return { record, applied: false, status: current };
  }
  const next: ApprovalRecord = { kind: "permission", status: behavior, createdAt: record.createdAt };
  return { record: next, applied: true, status: behavior };
}

/** Pure: cancels a pending record (best-effort, e.g. because the laptop
 * became active or the poll timed out). No-op if already resolved. */
export function applyCancel(
  record: ApprovalRecord | undefined,
  now: number,
): { record: ApprovalRecord | undefined; applied: boolean; status: ApprovalStatus } {
  const current = effectiveStatus(record, now);
  if (current !== "pending" || !record) {
    return { record, applied: false, status: current };
  }
  const next: ApprovalRecord = { kind: "permission", status: "cancelled", createdAt: record.createdAt };
  return { record: next, applied: true, status: "cancelled" };
}

export function newRecord(now: number): ApprovalRecord {
  return { kind: "permission", status: "pending", createdAt: now };
}

// --- Durable Object wrapper -------------------------------------------------
// Thin fetch-routed shell around the pure functions above (and the ones in
// questions.ts). One instance (addressed via idFromName("global") in
// index.ts) is enough: a single owner, low request volume, and DO's
// serialized execution is exactly what gives us "first answer wins" and a
// race-free question queue without extra locking.

export interface DurableObjectStateLike {
  storage: {
    get<T>(key: string): Promise<T | undefined>;
    put<T>(key: string, value: T): Promise<void>;
  };
}

const ACTIVE_KEY = "q:active";
const QUEUE_KEY = "q:queue";

export class ApprovalStore {
  private state: DurableObjectStateLike;

  constructor(state: DurableObjectStateLike) {
    this.state = state;
  }

  /** Skips past an active question that is no longer pending (expired, or
   * left behind when its WhatsApp send failed) so it can't swallow replies
   * or block the queue. `activated` is a queued question that just became
   * active and still needs its first message sent. */
  private async settleActive(now: number): Promise<{
    activeId: string | null;
    activated?: { id: string; record: QuestionRecord };
  }> {
    let activeId = (await this.state.storage.get<string | null>(ACTIVE_KEY)) ?? null;
    let queue = (await this.state.storage.get<string[]>(QUEUE_KEY)) ?? [];
    let record: QuestionRecord | undefined;
    let changed = false;

    while (activeId) {
      record = await this.state.storage.get<QuestionRecord>(activeId);
      if (record && questionEffectiveStatus(record, now, EXPIRY_MS) === "pending") break;
      ({ activeId, queue } = activateNext(queue));
      record = undefined;
      changed = true;
    }

    if (!changed) return { activeId };
    await this.state.storage.put(ACTIVE_KEY, activeId);
    await this.state.storage.put(QUEUE_KEY, queue);
    return { activeId, activated: activeId && record ? { id: activeId, record } : undefined };
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Date.now();
    const json = (body: unknown, status = 200) =>
      new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

    // --- Permission requests (Bash/Edit/etc. approve-deny) -----------------

    if (request.method === "POST" && url.pathname === "/create") {
      const { id } = (await request.json()) as { id: string };
      await this.state.storage.put(id, newRecord(now));
      return json({ ok: true });
    }

    if (request.method === "POST" && url.pathname === "/decide") {
      const { id, behavior } = (await request.json()) as { id: string; behavior: "allow" | "deny" };
      const record = await this.state.storage.get<ApprovalRecord>(id);
      const result = applyDecision(record, behavior, now);
      if (result.applied && result.record) await this.state.storage.put(id, result.record);
      return json({ applied: result.applied, status: result.status });
    }

    // --- AskUserQuestion ------------------------------------------------------

    if (request.method === "POST" && url.pathname === "/question/create") {
      const { id, questions } = (await request.json()) as { id: string; questions: QuestionInput[] };
      const record = newQuestionRecord(questions, now);
      await this.state.storage.put(id, record);

      const settled = await this.settleActive(now);
      const queue = (await this.state.storage.get<string[]>(QUEUE_KEY)) ?? [];
      const result = enqueueOrActivate(queue, settled.activeId, id);
      await this.state.storage.put(ACTIVE_KEY, result.activeId);
      await this.state.storage.put(QUEUE_KEY, result.queue);

      return json({ activate: result.shouldActivateNow, record, activated: settled.activated });
    }

    if (request.method === "GET" && url.pathname === "/question/record") {
      const id = url.searchParams.get("id") ?? "";
      const record = await this.state.storage.get<QuestionRecord>(id);
      return json({ record: record ?? null });
    }

    if (request.method === "GET" && url.pathname === "/question/active") {
      return json(await this.settleActive(now));
    }

    if (request.method === "POST" && url.pathname === "/question/answer") {
      const { id, qIndex, optIndex, freeText } = (await request.json()) as {
        id: string;
        qIndex: number;
        optIndex?: number;
        freeText?: string;
      };
      const record = await this.state.storage.get<QuestionRecord>(id);
      if (!record || questionEffectiveStatus(record, now, EXPIRY_MS) !== "pending") {
        return json({ applied: false, status: record ? questionEffectiveStatus(record, now, EXPIRY_MS) : "expired" });
      }

      const question = record.questions[qIndex];
      const answerLabel =
        question && typeof optIndex === "number" && question.options[optIndex]
          ? question.options[optIndex].label
          : parseFreeTextAnswer(freeText ?? "", question?.options ?? []);

      const result = applyAnswer(record, qIndex, answerLabel);
      if (!result.applied) {
        return json({ applied: false, status: record.status });
      }
      await this.state.storage.put(id, result.record);

      let activated: { id: string; record: QuestionRecord } | undefined;
      if (result.record.status === "answered") {
        const wasActive = (await this.state.storage.get<string | null>(ACTIVE_KEY)) === id;
        if (wasActive) {
          const queue = (await this.state.storage.get<string[]>(QUEUE_KEY)) ?? [];
          const next = activateNext(queue);
          await this.state.storage.put(ACTIVE_KEY, next.activeId);
          await this.state.storage.put(QUEUE_KEY, next.queue);
          if (next.activeId) {
            const nextRecord = await this.state.storage.get<QuestionRecord>(next.activeId);
            if (nextRecord) activated = { id: next.activeId, record: nextRecord };
          }
        }
      }

      return json({
        applied: true,
        status: result.record.status,
        currentIndex: result.record.currentIndex,
        questions: result.record.questions,
        answers: result.record.answers,
        activated,
      });
    }

    // --- Shared status/cancel (both kinds) --------------------------------

    if (request.method === "GET" && url.pathname === "/status") {
      const id = url.searchParams.get("id") ?? "";
      const record = await this.state.storage.get<AnyRecord>(id);

      if (record?.kind === "question") {
        const status = questionEffectiveStatus(record, now, EXPIRY_MS);
        if (status === "expired" && record.status === "pending") {
          await this.state.storage.put(id, { ...record, status: "expired" });
        }
        return json(status === "answered" ? { status, answers: record.answers } : { status });
      }

      const status = effectiveStatus(record as ApprovalRecord | undefined, now);
      if (record && status === "expired" && record.status === "pending") {
        await this.state.storage.put(id, { ...record, status: "expired" });
      }
      return json({ status });
    }

    if (request.method === "POST" && url.pathname === "/cancel") {
      const { id } = (await request.json()) as { id: string };
      const record = await this.state.storage.get<AnyRecord>(id);

      if (record?.kind === "question") {
        const result = cancelQuestion(record, now, EXPIRY_MS);
        if (result.applied && result.record) await this.state.storage.put(id, result.record);

        let activated: { id: string; record: QuestionRecord } | undefined;
        if (result.applied) {
          const wasActive = (await this.state.storage.get<string | null>(ACTIVE_KEY)) === id;
          if (wasActive) {
            const queue = (await this.state.storage.get<string[]>(QUEUE_KEY)) ?? [];
            const next = activateNext(queue);
            await this.state.storage.put(ACTIVE_KEY, next.activeId);
            await this.state.storage.put(QUEUE_KEY, next.queue);
            if (next.activeId) {
              const nextRecord = await this.state.storage.get<QuestionRecord>(next.activeId);
              if (nextRecord) activated = { id: next.activeId, record: nextRecord };
            }
          }
        }
        return json({ applied: result.applied, status: result.status, activated });
      }

      const result = applyCancel(record as ApprovalRecord | undefined, now);
      if (result.applied && result.record) await this.state.storage.put(id, result.record);
      return json({ applied: result.applied, status: result.status });
    }

    return json({ error: "not found" }, 404);
  }
}
