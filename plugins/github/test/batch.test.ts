import { describe, expect, it } from "vitest";
import { buildBatchMessage } from "../src/reviews/batch";
import type { ReviewThread } from "../src/reviews/threads";

const th = (over: Partial<ReviewThread>): ReviewThread => ({
  id: "x", path: "a.ts", line: 1, originalLine: 1, isOutdated: false, author: "al", body: "b", url: "u", ...over,
});
const PR = { owner: "o", repo: "r", number: 12 };

describe("buildBatchMessage", () => {
  it("groups by sorted path, then sorts by line, with the count first", () => {
    const msg = buildBatchMessage(PR, [
      th({ path: "src/b.ts", line: 20, author: "alice", body: "Rename." }),
      th({ path: "src/a.ts", line: 30, author: "bob", body: "Late." }),
      th({ path: "src/a.ts", line: 3, author: "carol", body: "Early." }),
    ]);
    expect(msg).toBe(
      [
        "3 review comments on PR #12 (o/r):",
        "",
        "## src/a.ts",
        "- L3 @carol: Early.",
        "- L30 @bob: Late.",
        "",
        "## src/b.ts",
        "- L20 @alice: Rename.",
      ].join("\n"),
    );
  });

  it("uses originalLine and (outdated) for an outdated thread without a line", () => {
    const msg = buildBatchMessage(PR, [th({ line: null, originalLine: 9, isOutdated: true, body: "Nit." })]);
    expect(msg).toContain("- L9 (outdated) @al: Nit.");
  });

  it("uses singular wording for one comment", () => {
    expect(buildBatchMessage(PR, [th({})])!.split("\n")[0]).toBe("1 review comment on PR #12 (o/r):");
  });

  it("indents continuation lines of multi-line bodies", () => {
    const msg = buildBatchMessage(PR, [th({ body: "one\ntwo" })]);
    expect(msg).toContain("- L1 @al: one\n  two");
  });

  it("returns null when nothing is selected", () => {
    expect(buildBatchMessage(PR, [])).toBeNull();
  });
});
