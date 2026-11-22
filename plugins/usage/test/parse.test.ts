import { describe, expect, it } from "vitest";
import { parseClaude } from "../src/parse/claude";
import { parseCodex } from "../src/parse/codex";
import claudeFull from "./fixtures/claude-full.json";
import claudePartial from "./fixtures/claude-partial.json";
import claudeEmpty from "./fixtures/claude-empty.json";
import codexFull from "./fixtures/codex-full.json";
import codexPartial from "./fixtures/codex-partial.json";
import codexEmpty from "./fixtures/codex-empty.json";

describe("parseClaude", () => {
  it("reads session, weekly, and the model weeklies in display order", () => {
    expect(parseClaude(claudeFull)).toEqual([
      { key: "session", label: "Session", percent: 42, resetsAtMs: Date.UTC(2026, 0, 1, 14, 14) },
      { key: "weekly", label: "Weekly", percent: 76.4, resetsAtMs: Date.UTC(2026, 0, 4, 16) },
      { key: "weekly-opus", label: "Weekly Opus", percent: 91, resetsAtMs: Date.UTC(2026, 0, 4, 16) },
      { key: "weekly-sonnet", label: "Weekly Sonnet", percent: 12.2, resetsAtMs: Date.UTC(2026, 0, 4, 16) },
    ]);
  });

  it("skips null, malformed and unknown windows and tolerates a missing reset", () => {
    expect(parseClaude(claudePartial)).toEqual([{ key: "session", label: "Session", percent: 3 }]);
  });

  it("returns nothing for an empty or non-object response", () => {
    expect(parseClaude(claudeEmpty)).toEqual([]);
    expect(parseClaude(null)).toEqual([]);
    expect(parseClaude("oops")).toEqual([]);
  });

  it("clamps utilization into 0…100", () => {
    expect(parseClaude({ five_hour: { utilization: 130 } })[0].percent).toBe(100);
    expect(parseClaude({ five_hour: { utilization: -4 } })[0].percent).toBe(0);
  });
});

describe("parseCodex", () => {
  it("reads the primary and secondary windows with epoch-second resets", () => {
    expect(parseCodex(codexFull)).toEqual([
      { key: "session", label: "Session", percent: 42, resetsAtMs: 1767276840 * 1000 },
      { key: "weekly", label: "Weekly", percent: 95.5, resetsAtMs: 1767575000 * 1000 },
    ]);
  });

  it("tolerates missing fields", () => {
    expect(parseCodex(codexPartial)).toEqual([{ key: "session", label: "Session", percent: 7 }]);
  });

  it("returns nothing when rate_limit is absent or null", () => {
    expect(parseCodex(codexEmpty)).toEqual([]);
    expect(parseCodex({})).toEqual([]);
    expect(parseCodex(undefined)).toEqual([]);
  });
});
