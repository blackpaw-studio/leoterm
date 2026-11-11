import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { fetchAssignedIssues } from "../src/issues/list";
import { issuePrompt, issueSpawnAction, resolveRepoString } from "../src/issues/spawn";
import { utf8Length } from "../src/issues/utf8";
import { issuesList } from "../src/ui/issues";
import type { ParseRepo } from "../src/repoTypes";
import { createStubLeo } from "./stubLeo";

const parseRepo: ParseRepo = (raw) => {
  const m = /^(?:https:\/\/github\.com\/)?([^/\s]+)\/([^/\s]+?)(?:\.git)?$/.exec(raw);
  return m ? { owner: m[1], repo: m[2] } : null;
};
const agent = (name: string, repo: string | null) => ({ name, machine: "m", status: "idle", repo, branch: "b", hasWorktree: true });
const issue = (over: Record<string, unknown> = {}) => ({
  number: 7,
  title: "Fix it",
  body: "details",
  html_url: "https://github.com/Acme/Widget/issues/7",
  repository: { full_name: "Acme/Widget" },
  ...over,
});
const URL_ = "https://api.github.com/issues?filter=assigned&state=open&per_page=100";

describe("fetchAssignedIssues", () => {
  it("drops pull requests and maps fields", async () => {
    const stub = createStubLeo();
    stub.route("GET", URL_, { body: [issue(), issue({ number: 8, pull_request: {} }), issue({ number: 9, body: null })] });
    const res = await fetchAssignedIssues(createGitHubClient(stub.leo, stub.clock), "tok");
    expect(res).toMatchObject({ ok: true });
    if (!res.ok) throw new Error();
    expect(res.value.map((i) => i.number)).toEqual([7, 9]);
    expect(res.value[0]).toEqual({ number: 7, title: "Fix it", body: "details", url: issue().html_url, repo: "Acme/Widget" });
    expect(res.value[1].body).toBe("");
  });

  it("serves the cached list on a 304", async () => {
    const stub = createStubLeo();
    stub.route("GET", URL_, { headers: { etag: '"x"' }, body: [issue()] }, { status: 304 });
    const client = createGitHubClient(stub.leo, stub.clock);
    await fetchAssignedIssues(client, "tok");
    const again = await fetchAssignedIssues(client, "tok");
    expect(again).toMatchObject({ ok: true, value: [{ number: 7 }] });
    expect(stub.fetches[1].headers["If-None-Match"]).toBe('"x"');
  });

  it("passes errors through", async () => {
    const stub = createStubLeo();
    stub.route("GET", URL_, { status: 401, body: {} });
    const res = await fetchAssignedIssues(createGitHubClient(stub.leo, stub.clock), "tok");
    expect(res).toEqual({ ok: false, error: { kind: "Unauthorized" } });
  });
});

describe("issuePrompt", () => {
  const base = { number: 1, title: "T", url: "https://u", repo: "a/b" };
  it("is title, url, blank line, body", () => {
    expect(issuePrompt({ ...base, body: "hello" })).toBe("T\nhttps://u\n\nhello");
  });
  it("caps the body at 8 KB of UTF-8 without splitting a code point, and says so", () => {
    const body = "é".repeat(5000); // 10000 bytes
    const out = issuePrompt({ ...base, body });
    const kept = out.slice("T\nhttps://u\n\n".length).replace("…(truncated)", "");
    expect(utf8Length(kept)).toBeLessThanOrEqual(8192);
    expect(utf8Length(kept)).toBeGreaterThan(8190);
    expect(out.endsWith("…(truncated)")).toBe(true);
    expect(kept).not.toContain("�");
  });
  it("does not mark short bodies", () => {
    expect(issuePrompt({ ...base, body: "x".repeat(8192) })).not.toContain("truncated");
  });
});

describe("resolveRepoString", () => {
  it("reuses the raw repo string of an existing agent on the same repo, case-insensitively", () => {
    const agents = [agent("a", "/local/path"), agent("b", "https://github.com/acme/widget.git")];
    expect(resolveRepoString("Acme/Widget", agents, parseRepo)).toBe("https://github.com/acme/widget.git");
  });
  it("falls back to owner/repo", () => {
    expect(resolveRepoString("Acme/Widget", [agent("a", null), agent("c", "other/repo")], parseRepo)).toBe("Acme/Widget");
  });
});

describe("issueSpawnAction", () => {
  it("builds a spawnAgent with derived branch, no machine or template", () => {
    const action = issueSpawnAction({ number: 7, title: "Fix it", body: "d", url: "https://u", repo: "Acme/Widget" }, [], parseRepo);
    expect(action).toEqual({
      type: "spawnAgent",
      repo: "Acme/Widget",
      branch: "issue-7-fix-it",
      prompt: "Fix it\nhttps://u\n\nd",
      title: "New Agent from Issue",
    });
  });
});

describe("issuesList", () => {
  it("renders one item per issue with the spawn action first", () => {
    const tree = issuesList([{ number: 7, title: "Fix it", body: "", url: "https://u", repo: "Acme/Widget" }], [], parseRepo);
    expect(tree.type).toBe("List");
    const item = tree.sections[0].items[0];
    expect(item).toMatchObject({ id: "Acme/Widget#7", title: "Fix it", subtitle: "Acme/Widget #7" });
    expect(item.actions?.[0]).toMatchObject({ type: "spawnAgent", branch: "issue-7-fix-it" });
    expect(item.actions?.[1]).toMatchObject({ type: "openURL", url: "https://u" });
  });
  it("shows an empty state node text via a single section with no items", () => {
    expect(issuesList([], [], parseRepo).sections[0].items).toEqual([]);
  });
});
