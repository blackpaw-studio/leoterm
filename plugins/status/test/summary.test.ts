import { describe, expect, it } from "vitest";
import type { Meter, Node, Text, UsageSnapshot } from "../../sdk/leo";
import { buildSummary } from "../src/summary";

const nodes = (n: ReturnType<typeof buildSummary>): Node[] => (Array.isArray(n) ? n : [n]);
const textOf = (n: Text): string => n.runs.map((r) => r.text).join("");
const allText = (n: ReturnType<typeof buildSummary>): string =>
  nodes(n)
    .filter((x): x is Text => x.type === "Text")
    .map(textOf)
    .join("|");
const meterOf = (n: ReturnType<typeof buildSummary>): Meter | undefined =>
  nodes(n).find((x): x is Meter => x.type === "Meter");

const full: UsageSnapshot = {
  model: "Opus 5.5",
  context: {
    tokens: 42_000,
    window: 200_000,
    percent: 21,
    breakdown: { system: 6000, tools: 8000, mcp: 2000, memory: 1000, messages: 25_000 },
  },
  session: { tokens: 900_000, costUsd: 35.356 },
  rateLimits: [
    { kind: "five_hour", percentUsed: 3.4, resetsAt: "2026-11-12T05:00:00Z" },
    { kind: "seven_day", percentUsed: 50, resetsAt: "2026-11-16T05:00:00Z" },
  ],
};

describe("buildSummary", () => {
  it("renders the full strip", () => {
    const s = buildSummary(full);
    expect(allText(s)).toBe("Opus 5.5|21% · 5h 3% · $35.36");
    const model = nodes(s)[0] as Text;
    expect(model.runs[0].tone).toBe("accent1");
  });

  it("splits the meter by breakdown with the token count as help", () => {
    const m = meterOf(buildSummary(full))!;
    expect(m.max).toBe(200_000);
    expect(m.segments).toEqual([
      { value: 6000, tone: "accent1" },
      { value: 8000, tone: "accent2" },
      { value: 2000, tone: "accent3" },
      { value: 1000, tone: "accent4" },
      { value: 25_000, tone: "accent5" },
    ]);
    expect(m.help).toBe("42k / 200k tokens");
  });

  it("falls back to one total segment without a breakdown", () => {
    const m = meterOf(buildSummary({ context: { tokens: 42_000, window: 200_000, percent: 21 } }))!;
    expect(m.segments).toEqual([{ value: 42_000, tone: "accent1" }]);
  });

  it("skips absent breakdown categories", () => {
    const m = meterOf(buildSummary({ context: { tokens: 10, window: 100, percent: 10, breakdown: { tools: 4, messages: 6 } } }))!;
    expect(m.segments.map((s) => s.tone)).toEqual(["accent2", "accent5"]);
  });

  it("omits 5h when no five_hour limit is present", () => {
    const s = buildSummary({ ...full, rateLimits: [full.rateLimits![1]] });
    expect(allText(s)).toBe("Opus 5.5|21% · $35.36");
  });

  it("omits cost when absent", () => {
    const { session: _s, ...rest } = full;
    expect(allText(buildSummary(rest))).toBe("Opus 5.5|21% · 5h 3%");
  });

  it("omits the meter and percent without context", () => {
    const s = buildSummary({ model: "Opus 5.5", session: { tokens: 1, costUsd: 1 } });
    expect(meterOf(s)).toBeUndefined();
    expect(allText(s)).toBe("Opus 5.5|$1.00");
  });

  it("omits the model when unknown", () => {
    const { model: _m, ...rest } = full;
    expect(allText(buildSummary(rest))).toBe("21% · 5h 3% · $35.36");
  });

  it("shows a dash before the first response", () => {
    expect(allText(buildSummary(null))).toBe("—");
  });

  it("says so when the harness reports nothing", () => {
    expect(allText(buildSummary({}))).toBe("No usage data");
  });

  it("shows a dash when only unsummarised fields exist", () => {
    expect(allText(buildSummary({ git: { added: 1, removed: 2 } }))).toBe("—");
  });

  it("skips a meter with a zero window", () => {
    expect(meterOf(buildSummary({ context: { tokens: 0, window: 0, percent: 0 } }))).toBeUndefined();
  });
});
