import { describe, expect, it } from "vitest";
import type { Meter, Node, Text, UsageSnapshot } from "../../sdk/leo";
import { buildBody } from "../src/body";

const NOW = Date.UTC(2026, 10, 12, 0, 0, 0);
const at = (ms: number) => new Date(NOW + ms).toISOString();
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

const lines = (nodes: Node[]): string[] =>
  nodes.filter((n): n is Text => n.type === "Text").map((n) => n.runs.map((r) => r.text).join(""));
const meter = (nodes: Node[]): Meter | undefined => nodes.find((n): n is Meter => n.type === "Meter");
const body = (usage: UsageSnapshot | null, where: { workspace?: string; branch?: string } = {}) =>
  buildBody(usage, where, NOW);

const full: UsageSnapshot = {
  model: "Opus 5.5",
  effort: "high",
  context: {
    tokens: 80_000,
    window: 200_000,
    percent: 40,
    breakdown: { system: 29_000, tools: 8000, mcp: 2000, memory: 1000, messages: 40_000 },
    compactAt: 0.37,
  },
  session: { tokens: 1, costUsd: 35.356 },
  rateLimits: [
    { kind: "seven_day", percentUsed: 50, resetsAt: at(4 * DAY + 2 * HOUR) },
    { kind: "five_hour", percentUsed: 3.44, resetsAt: at(3 * HOUR + 50 * 60_000) },
  ],
  git: { added: 12, removed: 3 },
};
const where = { workspace: "~/.leo/agents/leoterm", branch: "main" };

describe("buildBody", () => {
  it("renders four aligned rows, the meter between the context label and its legend", () => {
    const out = body(full, where);
    expect(lines(out)).toEqual([
      "model    Opus 5.5 · thinking high",
      "where    ~/.l/a/leoterm · main (+12,−3)",
      "context  ",
      "         sys 29k · tools 8k · mcp 2k · mem 1k · chat 40k · 120k free · compacts at 37%",
      "limits   session 3.4% resets 3h 50m · weekly 50.0% resets 4d 2h · $35.36",
    ]);
    expect(out.map((n) => n.type)).toEqual(["Text", "Text", "Text", "Meter", "Text", "Text"]);
  });

  it("pads every label to one width in secondary mono so the values line up", () => {
    const labels = body(full, where)
      .filter((n): n is Text => n.type === "Text")
      .map((n) => n.runs[0]!)
      .filter((r) => r.text.trim() !== "");
    expect(labels.map((r) => r.text.length)).toEqual([9, 9, 9, 9]);
    expect(labels.every((r) => r.tone === "secondary" && r.mono === true)).toBe(true);
  });

  it("states the context percentage once, as the meter's label", () => {
    const out = body(full, where);
    expect(meter(out)!.label).toBe("40.0%");
    expect(lines(out).filter((l) => l.includes("40.0%"))).toEqual([]);
  });

  it("draws the context meter full width with the category segments", () => {
    const m = meter(body(full, where))!;
    expect(m.max).toBe(200_000);
    expect(m.segments.map((s) => s.tone)).toEqual(["accent1", "accent2", "accent3", "accent4", "accent5"]);
    expect(m.help).toBe("80k / 200k tokens");
  });

  it("counts tokens no category accounts for as other", () => {
    const usage: UsageSnapshot = {
      context: { tokens: 155_200, window: 200_000, percent: 77, breakdown: { system: 3000, messages: 151_000 } },
    };
    expect(lines(body(usage))).toContain("         sys 3k · chat 151k · 1.2k other · 45k free");
  });

  it("shows no other when the categories add up or the breakdown is unknown", () => {
    expect(lines(body(full, where)).some((l) => l.includes("other"))).toBe(false);
    const usage: UsageSnapshot = { context: { tokens: 50, window: 100, percent: 50 } };
    expect(lines(body(usage)).some((l) => l.includes("other"))).toBe(false);
  });

  it("prettifies a model id", () => {
    expect(lines(body({ model: "claude-sonnet-5-5[1m]" }))[0]).toBe("model    Sonnet 5.5 1M");
  });

  it("hides the effort without hiding the model", () => {
    const { effort: _e, ...rest } = full;
    expect(lines(body(rest, where))[0]).toBe("model    Opus 5.5");
  });

  it("hides the model row when neither model nor effort is known", () => {
    const { model: _m, effort: _e, ...rest } = full;
    expect(lines(body(rest, where)).some((l) => l.startsWith("model"))).toBe(false);
  });

  it("hides git stats, branch and workspace independently", () => {
    const { git: _g, ...rest } = full;
    expect(lines(body(rest, where))[1]).toBe("where    ~/.l/a/leoterm · main");
    expect(lines(body(full, { branch: "main" }))[1]).toBe("where    main (+12,−3)");
    expect(lines(body(full, {}))[1]).toBe("where    (+12,−3)");
    expect(lines(body(rest, {})).some((l) => l.startsWith("where"))).toBe(false);
  });

  it("shows git stats of zero as zero", () => {
    expect(lines(body({ ...full, git: { added: 0, removed: 0 } }, where))[1]).toBe(
      "where    ~/.l/a/leoterm · main (+0,−0)",
    );
  });

  it("hides the legend parts it does not know", () => {
    const usage: UsageSnapshot = { context: { tokens: 50, window: 100, percent: 50, breakdown: { tools: 10 } } };
    const out = lines(body(usage));
    expect(out).toContain("         tools 10 · 40 other · 50 free");
    expect(out.some((l) => l.includes("compacts"))).toBe(false);
  });

  it("omits free tokens when the context overflows", () => {
    const usage: UsageSnapshot = { context: { tokens: 120, window: 100, percent: 120 } };
    expect(lines(body(usage)).some((l) => l.includes("free"))).toBe(false);
  });

  it("without a window there is no meter and the percentage joins the label row", () => {
    const usage: UsageSnapshot = { context: { tokens: 5, window: 0, percent: 7 } };
    const out = body(usage);
    expect(meter(out)).toBeUndefined();
    expect(lines(out)[0]).toBe("context  7.0%");
  });

  it("hides the context rows without context", () => {
    const { context: _c, ...rest } = full;
    expect(lines(body(rest, where)).some((l) => l.startsWith("context"))).toBe(false);
    expect(meter(body(rest, where))).toBeUndefined();
  });

  it("drops the limits row when every part is absent", () => {
    const { rateLimits: _r, session: _s, ...rest } = full;
    expect(lines(body(rest, where)).some((l) => l.startsWith("limits"))).toBe(false);
  });

  it("shows cost alone on the limits row", () => {
    const { rateLimits: _r, ...rest } = full;
    expect(lines(body(rest, where)).slice(-1)[0]).toBe("limits   $35.36");
  });

  it("keeps the limits when there is no session cost", () => {
    const { session: _s, ...rest } = full;
    expect(lines(body(rest, where)).slice(-1)[0]).toBe("limits   session 3.4% resets 3h 50m · weekly 50.0% resets 4d 2h");
  });

  it("labels unknown limit kinds as sent and survives a bad time", () => {
    const usage: UsageSnapshot = { rateLimits: [{ kind: "opus_weekly", percentUsed: 5, resetsAt: "later" }] };
    expect(lines(body(usage))).toEqual(["limits   opus_weekly 5.0%"]);
  });

  it("shows a limit without its resets part when there is no reset time", () => {
    const usage: UsageSnapshot = { rateLimits: [{ kind: "five_hour", percentUsed: 3.44 }] };
    expect(lines(body(usage))).toEqual(["limits   session 3.4%"]);
  });

  it("shows empty states", () => {
    expect(body(null)).toEqual([expect.objectContaining({ type: "EmptyState", title: "No usage data yet" })]);
    expect(body({})).toEqual([expect.objectContaining({ type: "EmptyState", title: "No usage data" })]);
  });
});
