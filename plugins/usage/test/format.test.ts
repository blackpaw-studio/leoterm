import { describe, expect, it } from "vitest";
import { clip, clockTime, percentText, resetsIn, updatedAgo } from "../src/format";

const NOW = Date.UTC(2026, 0, 1, 12, 0, 0);
const min = 60_000;

describe("percentText", () => {
  it("rounds to a whole percent", () => {
    expect(percentText(42)).toBe("42%");
    expect(percentText(76.4)).toBe("76%");
    expect(percentText(99.6)).toBe("100%");
  });
});

describe("resetsIn", () => {
  it.each([
    [14 * min, "Resets in 14m"],
    [(2 * 60 + 14) * min, "Resets in 2h 14m"],
    [2 * 60 * min, "Resets in 2h"],
    [(3 * 24 + 4) * 60 * min, "Resets in 3d 4h"],
    [30_000, "Resets in <1m"],
    [-5 * min, "Resetting now"],
  ])("offset %s ms → %s", (offset, text) => {
    expect(resetsIn(NOW + offset, NOW)).toBe(text);
  });
});

describe("updatedAgo", () => {
  it.each([
    [10_000, "Updated just now"],
    [3 * min, "Updated 3m ago"],
    [125 * min, "Updated 2h ago"],
    [50 * 60 * min, "Updated 2d ago"],
  ])("%s ms ago → %s", (age, text) => {
    expect(updatedAgo(NOW - age, NOW)).toBe(text);
  });
});

describe("clip", () => {
  it("leaves short text alone and ellipsizes long text within the limit", () => {
    expect(clip("short", 10)).toBe("short");
    expect(clip("x".repeat(300), 80)).toHaveLength(80);
    expect(clip("x".repeat(300), 80).endsWith("…")).toBe(true);
    expect(clip("x".repeat(80), 80)).toHaveLength(80);
  });
});

describe("clockTime", () => {
  it("formats local 12-hour time like the design's 8:57 PM", () => {
    expect(clockTime(Date.UTC(2026, 0, 2, 1, 57))).toBe("8:57 PM"); // TZ pinned to America/New_York in vitest.config
    expect(clockTime(Date.UTC(2026, 0, 1, 17, 5))).toBe("12:05 PM");
    expect(clockTime(Date.UTC(2026, 0, 1, 5, 0))).toBe("12:00 AM");
  });
});
