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
  it("renders the four rows", () => {
    expect(lines(body(full, where))).toEqual([
      "Model  Opus 5.5  thinking high",
      "Where  ~/.l/a/leoterm  main  (+12,−3)",
      "Context  40.0%",
      "sys 29k · tools 8k · mcp 2k · mem 1k · chat 40k · free 120k · compacts at 37%",
      "Limits",
      "session 3.4% resets 3h 50m",
      "weekly 50.0% resets 4d 2h",
      "cost $35.36",
    ]);
  });

  it("draws the context meter full width with the category segments", () => {
    const m = meter(body(full, where))!;
    expect(m.max).toBe(200_000);
    expect(m.segments.map((s) => s.tone)).toEqual(["accent1", "accent2", "accent3", "accent4", "accent5"]);
    expect(m.label).toBe("40.0%");
    expect(m.help).toBe("80k / 200k tokens");
  });

  it("prettifies a model id", () => {
    expect(lines(body({ model: "claude-sonnet-5-5[1m]" }))[0]).toBe("Model  Sonnet 5.5 1M");
  });

  it("hides the effort without hiding the model", () => {
    const { effort: _e, ...rest } = full;
    expect(lines(body(rest, where))[0]).toBe("Model  Opus 5.5");
  });

  it("hides the model row when neither model nor effort is known", () => {
    const { model: _m, effort: _e, ...rest } = full;
    expect(lines(body(rest, where)).some((l) => l.startsWith("Model"))).toBe(false);
  });

  it("hides git stats, branch and workspace independently", () => {
    const { git: _g, ...rest } = full;
    expect(lines(body(rest, where))[1]).toBe("Where  ~/.l/a/leoterm  main");
    expect(lines(body(full, { branch: "main" }))[1]).toBe("Where  main  (+12,−3)");
    expect(lines(body(rest, {})).some((l) => l.startsWith("Where"))).toBe(false);
  });

  it("shows git stats of zero as zero", () => {
    expect(lines(body({ ...full, git: { added: 0, removed: 0 } }, where))[1]).toBe("Where  ~/.l/a/leoterm  main  (+0,−0)");
  });

  it("hides the legend parts it does not know", () => {
    const usage: UsageSnapshot = { context: { tokens: 50, window: 100, percent: 50, breakdown: { tools: 10 } } };
    const out = lines(body(usage));
    expect(out).toContain("tools 10 · free 50");
    expect(out.some((l) => l.includes("compacts"))).toBe(false);
  });

  it("omits free tokens when the context overflows", () => {
    const usage: UsageSnapshot = { context: { tokens: 120, window: 100, percent: 120 } };
    expect(lines(body(usage)).some((l) => l.includes("free"))).toBe(false);
  });

  it("hides the context row without context", () => {
    const { context: _c, ...rest } = full;
    const out = lines(body(rest, where));
    expect(out.some((l) => l.startsWith("Context"))).toBe(false);
    expect(meter(body(rest, where))).toBeUndefined();
  });

  it("hides the limits header and cost when absent", () => {
    const { rateLimits: _r, session: _s, ...rest } = full;
    expect(lines(body(rest, where)).some((l) => l.startsWith("Limits") || l.startsWith("cost"))).toBe(false);
  });

  it("shows cost alone under Limits", () => {
    const { rateLimits: _r, ...rest } = full;
    expect(lines(body(rest, where)).slice(-2)).toEqual(["Limits", "cost $35.36"]);
  });

  it("labels unknown limit kinds as sent and survives a bad time", () => {
    const usage: UsageSnapshot = { rateLimits: [{ kind: "opus_weekly", percentUsed: 5, resetsAt: "later" }] };
    expect(lines(body(usage))).toEqual(["Limits", "opus_weekly 5.0%"]);
  });

  it("shows empty states", () => {
    expect(body(null)).toEqual([expect.objectContaining({ type: "EmptyState", title: "No usage data yet" })]);
    expect(body({})).toEqual([expect.objectContaining({ type: "EmptyState", title: "No usage data" })]);
  });
});
