import { describe, expect, it } from "vitest";
import { branchName } from "../src/issues/branchName";

describe("branchName", () => {
  it.each([
    [12, "Fix the Bug", "issue-12-fix-the-bug"],
    [3, "Café déjà vu", "issue-3-cafe-deja-vu"],
    [4, "Crash 💥 on launch!!", "issue-4-crash-on-launch"],
    [5, "a --- b ___ c", "issue-5-a-b-c"],
    [6, "  (leading) and trailing...  ", "issue-6-leading-and-trailing"],
    [7, "", "issue-7"],
    [8, "💥🔥", "issue-8"],
  ])("#%i %j → %s", (n, title, expected) => {
    expect(branchName(n, title)).toBe(expected);
  });

  it("cuts the slug to 40 characters and re-trims a dash the cut lands on", () => {
    const a39 = "a".repeat(39);
    expect(branchName(9, `${a39} bbb`)).toBe(`issue-9-${a39}`);
    expect(branchName(9, "a".repeat(60))).toBe(`issue-9-${"a".repeat(40)}`);
  });
});
