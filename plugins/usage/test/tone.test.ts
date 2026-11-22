import { describe, expect, it } from "vitest";
import type { UsageWindow } from "../src/window";
import { toneFor, worstTone, highestWindow } from "../src/tone";

describe("toneFor", () => {
  it.each([
    [0, "success"],
    [74.9, "success"],
    [75, "warning"],
    [89.9, "warning"],
    [90, "failure"],
    [100, "failure"],
  ])("%s%% is %s", (percent, tone) => {
    expect(toneFor(percent)).toBe(tone);
  });
});

describe("highestWindow", () => {
  it("picks the window with the highest percent", () => {
    const w: UsageWindow[] = [
      { key: "session", label: "Session", percent: 10 },
      { key: "weekly", label: "Weekly", percent: 80 },
    ];
    expect(highestWindow(w)?.key).toBe("weekly");
  });
  it("is undefined for no windows", () => {
    expect(highestWindow([])).toBeUndefined();
  });
});

describe("worstTone", () => {
  it("ranks failure over warning over success and ignores empty input", () => {
    expect(worstTone(["success", "warning", "failure"])).toBe("failure");
    expect(worstTone(["success", "warning"])).toBe("warning");
    expect(worstTone([])).toBeUndefined();
  });
});
