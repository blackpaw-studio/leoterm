import { describe, expect, it } from "vitest";
import { percentText, resetsIn, updatedAgo } from "../src/format";

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
    [14 * min, "resets in 14m"],
    [(2 * 60 + 14) * min, "resets in 2h 14m"],
    [2 * 60 * min, "resets in 2h"],
    [(3 * 24 + 4) * 60 * min, "resets in 3d 4h"],
    [30_000, "resets in <1m"],
    [-5 * min, "resetting now"],
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
