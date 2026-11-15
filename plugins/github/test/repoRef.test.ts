import { describe, expect, it } from "vitest";
import { isMapped, parseRepo, sameRepo } from "../src/repoRef";

const O = { owner: "Owner", repo: "Repo" };

describe("parseRepo", () => {
  it.each([
    ["Owner/Repo", O],
    ["https://github.com/Owner/Repo", O],
    ["https://github.com/Owner/Repo.git", O],
    ["https://github.com/Owner/Repo/", O],
    ["https://github.com/Owner/Repo.git/", O],
    ["http://github.com/Owner/Repo", O],
    ["https://user:tok@github.com/Owner/Repo.git", O],
    ["https://www.github.com/Owner/Repo", O],
    ["git@github.com:Owner/Repo.git", O],
    ["git@github.com:Owner/Repo", O],
    ["ssh://git@github.com/Owner/Repo.git", O],
    ["github.com/Owner/Repo", O],
    ["  Owner/Repo  ", O],
    ["a.b/c-d_e.f", { owner: "a.b", repo: "c-d_e.f" }],
  ])("accepts %s", (raw, want) => expect(parseRepo(raw)).toEqual(want));

  it.each([
    "",
    "/Users/evan/code/repo",
    "~/code/repo",
    "./owner/repo",
    "https://ghe.example.com/Owner/Repo",
    "git@gitlab.com:Owner/Repo.git",
    "https://github.com/Owner/Repo/pull/3",
    "a/b/c",
    "owner",
    "https://github.com/Owner",
    "https://evilgithub.com/Owner/Repo",
    "https://github.com.evil.com/Owner/Repo",
    "Owner/.git",
    "own er/repo",
  ])("rejects %j", (raw) => expect(parseRepo(raw)).toBeNull());
});

describe("sameRepo / isMapped", () => {
  it("compares case-insensitively", () => expect(sameRepo({ owner: "A", repo: "B" }, { owner: "a", repo: "b" })).toBe(true));
  it("maps only with a parseable repo and a non-empty branch", () => {
    expect(isMapped({ repo: "o/r", branch: "feat" })).toBe(true);
    expect(isMapped({ repo: "o/r", branch: "" })).toBe(false);
    expect(isMapped({ repo: "o/r", branch: null })).toBe(false);
    expect(isMapped({ repo: "/tmp/x", branch: "feat" })).toBe(false);
    expect(isMapped({ repo: null, branch: "feat" })).toBe(false);
  });
});
