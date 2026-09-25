import { describe, expect, it } from "vitest";
import {
  activateNext,
  applyAnswer,
  buildQuestionListMessage,
  buildRowId,
  enqueueOrActivate,
  MAX_ROWS,
  newQuestionRecord,
  parseFreeTextAnswer,
  parseRowId,
  questionEffectiveStatus,
  ROW_DESC_MAX,
  ROW_TITLE_MAX,
  type QuestionInput,
} from "../src/questions";

const singleSelect: QuestionInput = {
  question: "How should I format the output?",
  header: "Format",
  options: [
    { label: "Summary", description: "Brief overview" },
    { label: "Detailed", description: "Full explanation" },
  ],
  multiSelect: false,
};

const multiSelect: QuestionInput = {
  question: "Which sections should I include?",
  header: "Sections",
  options: [
    { label: "Intro", description: "Opening" },
    { label: "Body", description: "Main content" },
    { label: "Conclusion", description: "Wrap-up" },
  ],
  multiSelect: true,
};

describe("buildRowId / parseRowId", () => {
  it("round-trips a normal option row", () => {
    const id = buildRowId("abc-123", 2, 1);
    expect(parseRowId(id)).toEqual({ id: "abc-123", qIndex: 2, opt: 1 });
  });

  it("round-trips the 'other' row", () => {
    const id = buildRowId("abc-123", 0, "other");
    expect(parseRowId(id)).toEqual({ id: "abc-123", qIndex: 0, opt: "other" });
  });

  it("returns null for an unrelated id (e.g. allow:<id>)", () => {
    expect(parseRowId("allow:abc-123")).toBeNull();
  });
});

describe("buildQuestionListMessage", () => {
  it("builds a row per option plus a trailing Other row", () => {
    const message = buildQuestionListMessage({ to: "1", id: "abc", qIndex: 0, q: singleSelect });
    const rows = message.interactive.action.sections[0].rows;
    expect(rows).toHaveLength(singleSelect.options.length + 1);
    expect(rows[rows.length - 1]).toEqual({ id: buildRowId("abc", 0, "other"), title: "Other (type reply)" });
  });

  it("caps rows at MAX_ROWS including Other", () => {
    const manyOptions: QuestionInput = {
      question: "Pick one",
      options: Array.from({ length: 15 }, (_, i) => ({ label: `Option ${i}` })),
    };
    const message = buildQuestionListMessage({ to: "1", id: "abc", qIndex: 0, q: manyOptions });
    expect(message.interactive.action.sections[0].rows.length).toBeLessThanOrEqual(MAX_ROWS);
  });

  it("truncates long labels and descriptions to WhatsApp's row limits", () => {
    const q: QuestionInput = {
      question: "Pick one",
      options: [{ label: "x".repeat(50), description: "y".repeat(100) }],
    };
    const message = buildQuestionListMessage({ to: "1", id: "abc", qIndex: 0, q });
    const row = message.interactive.action.sections[0].rows[0];
    expect(row.title.length).toBeLessThanOrEqual(ROW_TITLE_MAX);
    expect(row.description!.length).toBeLessThanOrEqual(ROW_DESC_MAX);
  });

  it("numbers options and asks for a comma-separated reply for multiSelect", () => {
    const message = buildQuestionListMessage({ to: "1", id: "abc", qIndex: 0, q: multiSelect });
    expect(message.interactive.body.text).toContain("1. Intro");
    expect(message.interactive.body.text).toContain("2. Body");
    expect(message.interactive.body.text).toContain("reply with numbers");
  });
});

describe("parseFreeTextAnswer", () => {
  it("maps a single number to its option label", () => {
    expect(parseFreeTextAnswer("2", singleSelect.options)).toBe("Detailed");
  });

  it("maps comma-separated numbers to joined labels", () => {
    expect(parseFreeTextAnswer("1, 3", multiSelect.options)).toBe("Intro, Conclusion");
  });

  it("falls back to the raw text when it isn't a valid option list", () => {
    expect(parseFreeTextAnswer("I don't know", singleSelect.options)).toBe("I don't know");
  });

  it("falls back to raw text when a number is out of range", () => {
    expect(parseFreeTextAnswer("99", singleSelect.options)).toBe("99");
  });
});

describe("questionEffectiveStatus", () => {
  it("is expired for an unknown record", () => {
    expect(questionEffectiveStatus(undefined, Date.now(), 1000)).toBe("expired");
  });

  it("expires a pending record past the expiry window", () => {
    const now = Date.now();
    const record = newQuestionRecord([singleSelect], now);
    expect(questionEffectiveStatus(record, now + 1001, 1000)).toBe("expired");
  });
});

describe("applyAnswer", () => {
  it("records the answer and advances to the next question", () => {
    const now = Date.now();
    const record = newQuestionRecord([singleSelect, multiSelect], now);
    const result = applyAnswer(record, 0, "Detailed");
    expect(result.applied).toBe(true);
    expect(result.record.status).toBe("pending");
    expect(result.record.currentIndex).toBe(1);
    expect(result.record.answers[singleSelect.question]).toBe("Detailed");
  });

  it("marks the record answered once the last question is answered", () => {
    const now = Date.now();
    const record = newQuestionRecord([singleSelect], now);
    const result = applyAnswer(record, 0, "Summary");
    expect(result.record.status).toBe("answered");
    expect(result.record.answers).toEqual({ [singleSelect.question]: "Summary" });
  });

  it("rejects a stale tap for a question index that's no longer current", () => {
    const now = Date.now();
    const record = newQuestionRecord([singleSelect, multiSelect], now);
    const advanced = applyAnswer(record, 0, "Summary").record;
    const stale = applyAnswer(advanced, 0, "Detailed"); // qIndex 0 already answered
    expect(stale.applied).toBe(false);
    expect(stale.record).toBe(advanced);
  });

  it("rejects an answer once the record is no longer pending", () => {
    const now = Date.now();
    const record = newQuestionRecord([singleSelect], now);
    const done = applyAnswer(record, 0, "Summary").record;
    const again = applyAnswer(done, 0, "Detailed");
    expect(again.applied).toBe(false);
  });
});

describe("question queue", () => {
  it("activates immediately when nothing is active", () => {
    const result = enqueueOrActivate([], null, "q1");
    expect(result).toEqual({ queue: [], activeId: "q1", shouldActivateNow: true });
  });

  it("queues behind an active question", () => {
    const result = enqueueOrActivate([], "q1", "q2");
    expect(result).toEqual({ queue: ["q2"], activeId: "q1", shouldActivateNow: false });
  });

  it("activates the next queued question in FIFO order", () => {
    const result = activateNext(["q2", "q3"]);
    expect(result).toEqual({ queue: ["q3"], activeId: "q2" });
  });

  it("activating an empty queue leaves nothing active", () => {
    expect(activateNext([])).toEqual({ queue: [], activeId: null });
  });
});
