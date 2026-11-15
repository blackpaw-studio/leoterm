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
  effort: "high",
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
  it("renders model, effort and usage only", () => {
    const s = buildSummary(full);
    expect(allText(s)).toBe("Opus 5.5 · high|21% · 5h 3%");
    const model = nodes(s)[0] as Text;
    expect(model.runs[0].tone).toBe("accent1");
    expect(model.runs[1].tone).toBe("secondary");
  });

  it("never renders a context meter", () => {
    expect(meterOf(buildSummary(full))).toBeUndefined();
    expect(nodes(buildSummary(full)).every((n) => n.type === "Text")).toBe(true);
  });

  it("never renders cost", () => {
    expect(allText(buildSummary(full))).not.toContain("$");
    expect(allText(buildSummary({ model: "Opus 5.5", session: { tokens: 1, costUsd: 1 } }))).toBe("Opus 5.5");
  });

  it("prettifies a model id", () => {
    expect(allText(buildSummary({ model: "claude-opus-5-5" }))).toBe("Opus 5.5");
  });

  it("shows the model alone when effort is unknown", () => {
    const { effort: _e, ...rest } = full;
    expect(allText(buildSummary(rest))).toBe("Opus 5.5|21% · 5h 3%");
  });

  it("omits 5h when no five_hour limit is present", () => {
    const s = buildSummary({ ...full, rateLimits: [full.rateLimits![1]] });
    expect(allText(s)).toBe("Opus 5.5 · high|21%");
  });

  it("shows 5h without a reset time", () => {
    const s = buildSummary({ ...full, rateLimits: [{ kind: "five_hour", percentUsed: 3.4 }] });
    expect(allText(s)).toBe("Opus 5.5 · high|21% · 5h 3%");
  });

  it("omits the model when unknown", () => {
    const { model: _m, effort: _e, ...rest } = full;
    expect(allText(buildSummary(rest))).toBe("21% · 5h 3%");
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
});
