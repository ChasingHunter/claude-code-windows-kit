// AskUserQuestion support: WhatsApp interactive "list" messages (up to 10
// rows, the last one always "Other (type reply)"), plus the pure state
// machine for answering 1-4 questions per AskUserQuestion call, one at a
// time, with a single-active-question queue so two overlapping
// AskUserQuestion calls don't interleave in the same WhatsApp chat.
//
// Row ids are self-describing (`q:<id>:<qIndex>:<optIndex|other>`), so the
// webhook handler never needs extra lookups to know which question/option a
// tap refers to — only to resolve an option's label text and to validate the
// tap isn't stale (answering a question that already moved on).

export interface QuestionOption {
  label: string;
  description?: string;
}

export interface QuestionInput {
  question: string;
  header?: string;
  options: QuestionOption[];
  multiSelect?: boolean;
}

export type QuestionStatus = "pending" | "answered" | "cancelled" | "expired";

export interface QuestionRecord {
  kind: "question";
  status: QuestionStatus;
  createdAt: number;
  questions: QuestionInput[];
  currentIndex: number;
  answers: Record<string, string>;
}

export const ROW_TITLE_MAX = 24;
export const ROW_DESC_MAX = 72;
export const MAX_ROWS = 10; // WhatsApp list message cap, across all rows including "Other"
export const LIST_BODY_MAX = 1024;

export function newQuestionRecord(questions: QuestionInput[], now: number): QuestionRecord {
  return { kind: "question", status: "pending", createdAt: now, questions, currentIndex: 0, answers: {} };
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, Math.max(0, max - 1)) + "…";
}

export function buildRowId(id: string, qIndex: number, opt: number | "other"): string {
  return `q:${id}:${qIndex}:${opt}`;
}

export function parseRowId(rowId: string): { id: string; qIndex: number; opt: number | "other" } | null {
  const match = /^q:(.+):(\d+):(other|\d+)$/.exec(rowId);
  if (!match) return null;
  return { id: match[1], qIndex: Number(match[2]), opt: match[3] === "other" ? "other" : Number(match[3]) };
}

export interface ListMessage {
  messaging_product: "whatsapp";
  to: string;
  type: "interactive";
  interactive: {
    type: "list";
    body: { text: string };
    action: {
      button: string;
      sections: Array<{ rows: Array<{ id: string; title: string; description?: string }> }>;
    };
  };
}

/** Builds the WhatsApp list message for question `qIndex` of an
 * AskUserQuestion call. multiSelect questions additionally number the
 * options in the body and ask for a comma-separated numeric reply, since a
 * single WhatsApp list tap can only pick one row. */
export function buildQuestionListMessage(params: {
  to: string;
  id: string;
  qIndex: number;
  q: QuestionInput;
}): ListMessage {
  const { to, id, qIndex, q } = params;
  const options = q.options.slice(0, MAX_ROWS - 1); // reserve one row for "Other"

  let bodyText = q.question;
  if (q.multiSelect) {
    const numbered = options.map((o, i) => `${i + 1}. ${o.label}`).join("\n");
    bodyText = `${q.question}\n\n${numbered}\n\nMulti-select: reply with numbers, e.g. 1,3`;
  }

  const rows = options.map((o, i) => ({
    id: buildRowId(id, qIndex, i),
    title: truncate(o.label, ROW_TITLE_MAX),
    ...(o.description ? { description: truncate(o.description, ROW_DESC_MAX) } : {}),
  }));
  rows.push({ id: buildRowId(id, qIndex, "other"), title: "Other (type reply)" });

  return {
    messaging_product: "whatsapp",
    to,
    type: "interactive",
    interactive: {
      type: "list",
      body: { text: truncate(bodyText, LIST_BODY_MAX) },
      action: { button: q.header ? truncate(q.header, ROW_TITLE_MAX) : "Choose", sections: [{ rows }] },
    },
  };
}

/** Parses a free-text reply against the current question's options: a
 * comma-separated list of in-range option numbers ("1,3") resolves to the
 * joined option labels; anything else is used verbatim as a free-text
 * answer (covers both the "Other" flow and Claude's `response` escape
 * hatch). */
export function parseFreeTextAnswer(text: string, options: QuestionOption[]): string {
  const trimmed = text.trim();
  const parts = trimmed.split(",").map((p) => p.trim());
  const indices = parts.map((p) => Number(p));
  const allNumeric =
    indices.length > 0 && indices.every((n) => Number.isInteger(n) && n >= 1 && n <= options.length);
  if (allNumeric) {
    return indices.map((n) => options[n - 1].label).join(", ");
  }
  return trimmed;
}

export function questionEffectiveStatus(
  record: QuestionRecord | undefined,
  now: number,
  expiryMs: number,
): QuestionStatus | "expired" {
  if (!record) return "expired";
  if (record.status === "pending" && now - record.createdAt > expiryMs) return "expired";
  return record.status;
}

/** Pure: applies an answer to the question at `qIndex`. A stale tap (the
 * conversation already moved past that question, or the record isn't
 * pending) is rejected so the caller can tell the phone "already handled".
 * Advances to the next question, or marks the whole record "answered" once
 * every question has a value. */
export function applyAnswer(
  record: QuestionRecord,
  qIndex: number,
  answerLabel: string,
): { record: QuestionRecord; applied: boolean } {
  if (record.status !== "pending" || qIndex !== record.currentIndex) {
    return { record, applied: false };
  }
  const q = record.questions[record.currentIndex];
  const answers = { ...record.answers, [q.question]: answerLabel };
  const nextIndex = record.currentIndex + 1;
  const done = nextIndex >= record.questions.length;
  const next: QuestionRecord = {
    ...record,
    answers,
    currentIndex: nextIndex,
    status: done ? "answered" : "pending",
  };
  return { record: next, applied: true };
}

export function cancelQuestion(
  record: QuestionRecord | undefined,
  now: number,
  expiryMs: number,
): { record: QuestionRecord | undefined; applied: boolean; status: QuestionStatus | "expired" } {
  const current = questionEffectiveStatus(record, now, expiryMs);
  if (current !== "pending" || !record) {
    return { record, applied: false, status: current };
  }
  const next: QuestionRecord = { ...record, status: "cancelled" };
  return { record: next, applied: true, status: "cancelled" };
}

// --- Single-active-question queue -------------------------------------------
// Only one AskUserQuestion conversation is "live" in WhatsApp at a time.
// A second call arriving mid-conversation is queued and activated once the
// first is fully answered/cancelled/expired.

export function enqueueOrActivate(
  queue: string[],
  activeId: string | null,
  newId: string,
): { queue: string[]; activeId: string | null; shouldActivateNow: boolean } {
  if (activeId === null) {
    return { queue, activeId: newId, shouldActivateNow: true };
  }
  return { queue: [...queue, newId], activeId, shouldActivateNow: false };
}

export function activateNext(queue: string[]): { queue: string[]; activeId: string | null } {
  if (queue.length === 0) return { queue: [], activeId: null };
  const [next, ...rest] = queue;
  return { queue: rest, activeId: next };
}
