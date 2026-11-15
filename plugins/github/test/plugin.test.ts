import { describe, expect, it } from "vitest";
import type { Action, AgentRef, Form, ListItem, List, Node, SlotID } from "../../sdk/leo";
import { createPlugin } from "../src/plugin";
import { asResponse } from "./fixtureLoader";
import { allLimitProblems } from "./limits";
import { createStubLeo, START_MS, type StubLeo } from "./stubLeo";
import pullsOpen from "./fixtures/pulls-open.json";
import pulls304 from "./fixtures/pulls-304.json";
import runsMixed from "./fixtures/check-runs-mixed.json";
import statusEmpty from "./fixtures/status-empty.json";
import page1 from "./fixtures/review-threads-page1.json";
import page2 from "./fixtures/review-threads-page2.json";
import jobLog from "./fixtures/job-log.json";
import unauthorized from "./fixtures/401.json";

const API = "https://api.github.com";
const PULLS = API + "/repos/o/r/pulls?head=o:feat%2Fx&state=open&per_page=10";
const RUNS = API + "/repos/o/r/commits/bbb222/check-runs?per_page=100";
const STATUS = API + "/repos/o/r/commits/bbb222/status";
const LOG = API + "/repos/o/r/actions/jobs/9002/logs";
const ISSUES = API + "/issues?filter=assigned&state=open&per_page=100";

const alpha: AgentRef = { machine: "m", name: "alpha" };
const beta: AgentRef = { machine: "m", name: "beta" };
const snap = (a: AgentRef, repo: string | null, branch: string | null) => ({ ...a, status: "idle", repo, branch, hasWorktree: true });
const AGENTS = [snap(alpha, "o/r", "feat/x"), snap(beta, null, null)];

const accessory = (a: AgentRef): SlotID => ({ kind: "accessory", id: "pr", agent: a });
const view = (a: AgentRef): SlotID => ({ kind: "view", viewID: "github", agent: a });
const section: SlotID = { kind: "section", id: "assigned-issues" };
const palette = (commandID: string): SlotID => ({ kind: "palette", commandID });

const setup = () => {
  const stub = createStubLeo();
  stub.secretStore.set("token", "tok");
  stub.setAgents(AGENTS);
  stub.route("GET", PULLS, asResponse(pullsOpen as never));
  stub.route("GET", RUNS, asResponse(runsMixed as never));
  stub.route("GET", STATUS, asResponse(statusEmpty as never));
  stub.route("POST", API + "/graphql", asResponse(page1 as never), asResponse(page2 as never));
  stub.route("GET", LOG, asResponse(jobLog as never));
  createPlugin(stub.leo, stub.clock);
  return stub;
};

const nodes = (root: unknown): Node[] => (Array.isArray(root) ? (root as Node[]) : [root as Node]);
const types = (root: unknown): string[] => nodes(root).map((n) => n.type);
const itemsOf = (n: Node | undefined): ListItem[] => (n as List).sections.flatMap((s) => s.items);
const titleOf = (root: unknown): string | undefined => {
  const n = nodes(root)[0] as { title?: string } | undefined;
  return n?.title;
};
const asCallback = (a: Action | undefined): { id: string; payload: never } => {
  if (!a || a.type !== "callback") throw new Error("expected a callback action, got " + JSON.stringify(a));
  return a as never;
};
const pullFetches = (stub: StubLeo): number => stub.fetches.filter((f) => f.url === PULLS).length;
const noLimitProblems = (stub: StubLeo): void => expect(allLimitProblems(stub.renders)).toEqual([]);

const activateAll = async (stub: StubLeo): Promise<void> => {
  await stub.emit("activate");
  await stub.emit("activate", accessory(alpha));
  await stub.emit("activate", accessory(beta));
};

describe("activate", () => {
  it("draws a coloured PR chip for a mapped agent and nothing for an unmapped one", async () => {
    const stub = setup();
    await activateAll(stub);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ type: "Accessory", text: "#12", color: "failure" });
    expect(stub.lastRender(accessory(beta))).toEqual([]);
    expect(stub.fetches.every((f) => f.headers.Authorization === "Bearer tok")).toBe(true);
    noLimitProblems(stub);
  });

  it("shows sign-in on every slot when there is no token, and makes no request", async () => {
    const stub = setup();
    stub.secretStore.delete("token");
    await activateAll(stub);
    await stub.emit("activate", section);
    expect(titleOf(stub.lastRender(accessory(alpha)))).toBe("Sign in to GitHub");
    expect(titleOf(stub.lastRender(section))).toBe("Sign in to GitHub");
    expect(stub.fetches).toEqual([]);
  });
});

describe("polling", () => {
  it("re-renders nothing on a 304 cycle", async () => {
    const stub = setup();
    stub.route("GET", PULLS, asResponse(pullsOpen as never), asResponse(pulls304 as never));
    stub.route("GET", RUNS, asResponse(runsMixed as never), { status: 304, headers: { etag: 'W/"c1"' }, body: "" });
    await activateAll(stub);
    const before = stub.rendersFor(accessory(alpha)).length;
    await stub.tick(60);
    expect(pullFetches(stub)).toBe(2);
    expect(stub.fetches.find((f) => f.url === PULLS && f.headers["If-None-Match"] !== undefined)).toBeDefined();
    expect(stub.rendersFor(accessory(alpha)).length).toBe(before);
  });

  it("updates the chip when the checks change", async () => {
    const stub = setup();
    await activateAll(stub);
    const green = { status: 200, headers: {}, body: { check_runs: [{ id: 1, name: "b", status: "completed", conclusion: "success", app: { slug: "github-actions" } }] } };
    stub.route("GET", RUNS, green);
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12", color: "success" });
  });

  it("shows an error chip with the reason when a poll fails with an HTTP error, not the old status", async () => {
    const stub = setup();
    await activateAll(stub);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12", color: "failure" });
    stub.route("GET", PULLS, { status: 404, body: { message: "Not Found" } });
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ type: "Accessory", text: "err", color: "warning", help: "GitHub returned 404." });
    noLimitProblems(stub);
  });

  it("recovers from the error chip on the next good poll", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.route("GET", PULLS, { status: 500, body: {} }, asResponse(pullsOpen as never));
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "err" });
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12", color: "failure" });
    expect((stub.lastRender(accessory(alpha)) as { help?: string }).help).toBeUndefined();
  });

  it("keeps the last status through a transport failure", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.route("GET", PULLS, { reject: "offline" });
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12", color: "failure" });
  });

  it("shows the error chip when the refresh on branch change fails too", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.route("GET", API + "/repos/o/r/pulls?head=o:other&state=open&per_page=10", { status: 403, body: { message: "Forbidden" } });
    stub.setAgents([snap(alpha, "o/r", "other"), AGENTS[1]]);
    await stub.emit("agentsChanged");
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "err", color: "warning" });
  });

  it("drops an agent's slot when it leaves the list", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.setAgents([AGENTS[1]]);
    await stub.emit("agentsChanged");
    const before = pullFetches(stub);
    await stub.tick(120);
    expect(pullFetches(stub)).toBe(before);
  });

  it("refreshes an agent at once when its branch changes", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.route("GET", API + "/repos/o/r/pulls?head=o:other&state=open&per_page=10", { body: [] });
    stub.setAgents([snap(alpha, "o/r", "other"), AGENTS[1]]);
    await stub.emit("agentsChanged");
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ type: "Accessory", text: "no PR" });
  });
});

describe("view", () => {
  it("opens to the PR, its checks and the review comments", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, view(alpha));
    const renders = stub.rendersFor(view(alpha));
    expect(renders[0]).toEqual({ type: "Loading" });
    const root = stub.lastRender(view(alpha));
    expect(types(root)).toEqual(["Detail", "List", "Form"]);
    expect((nodes(root)[0] as { markdown: string }).markdown).toContain("#12 Newest");
    expect((nodes(root)[0] as { markdown: string }).markdown).toContain("Changes requested");
    expect(itemsOf(nodes(root)[1]).map((i) => i.title)).toContain("test");
    const form = nodes(root)[2] as Form;
    expect(form.fields.filter((f) => f.type === "checkbox").length).toBeGreaterThan(0);
    noLimitProblems(stub);
  });

  it("tells an unmapped agent it isn't on a GitHub branch", async () => {
    const stub = setup();
    await stub.emit("viewOpened", beta, view(beta));
    expect(titleOf(stub.lastRender(view(beta)))).toBe("This agent isn't on a GitHub branch");
    expect(stub.fetches).toEqual([]);
  });

  it("offers Create Pull Request when the branch has no PR", async () => {
    const stub = setup();
    stub.route("GET", PULLS, { body: [] });
    await stub.emit("viewOpened", alpha, view(alpha));
    const root = stub.lastRender(view(alpha));
    expect(titleOf(root)).toBe("No open pull request");
    expect(asCallback((nodes(root)[0] as { actions: Action[] }).actions[0]).id).toBe("create-pr:pick");
  });

  it("shows Error with Retry on a network failure, keeps polling, and retries", async () => {
    const stub = setup();
    stub.route("GET", PULLS, { reject: "offline" });
    await stub.emit("viewOpened", alpha, view(alpha));
    const root = stub.lastRender(view(alpha));
    expect(types(root)).toEqual(["Error"]);
    stub.route("GET", PULLS, asResponse(pullsOpen as never));
    const retry = asCallback((nodes(root)[0] as { retry: Action }).retry);
    await stub.emit("callback", retry.id, retry.payload);
    expect(types(stub.lastRender(view(alpha)))).toEqual(["Detail", "List", "Form"]);
    noLimitProblems(stub);
  });

  it("sends a failing check's log excerpt to the agent", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, view(alpha));
    const item = itemsOf(nodes(stub.lastRender(view(alpha)))[1]).find((i) => i.title === "test")!;
    const send = asCallback(item.actions?.[0]);
    const result = await stub.emit("callback", send.id, send.payload);
    expect(result).toMatchObject({ type: "sendToAgent", agent: alpha });
    expect(stub.fetches.find((f) => f.url === LOG)?.headers.Range).toBe("bytes=0-0");
    expect((result as { text: string }).text).toContain('Check "test" failed on PR #12 (o/r@feat/x)');
    expect((result as { text: string }).text).toContain("Error: boom");
    expect(itemsOf(nodes(stub.lastRender(view(alpha)))[1]).find((i) => i.title === "build")?.actions?.[0]).toMatchObject({ type: "openURL" });
  });

  it("rejects a send-failure payload with a forged repo", async () => {
    const stub = setup();
    const result = await stub.emit("callback", "send-failure", {
      agent: { ...alpha }, owner: "../x", repo: "y", branch: "b", prNumber: 1,
      check: { id: "1", name: "n", state: "failure", url: null, source: "actions", jobId: 1 },
    });
    expect(result ?? null).toBeNull();
    expect(stub.fetches).toEqual([]);
  });

  it("batches the selected review comments into one send", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, view(alpha));
    const form = nodes(stub.lastRender(view(alpha)))[2] as Form;
    stub.route("POST", API + "/graphql", asResponse(page1 as never), asResponse(page2 as never));
    const submit = asCallback(form.fields.find((f) => f.type === "submit")!.action);
    const box = form.fields.find((f) => f.type === "checkbox")!;
    const result = await stub.emit("callback", submit.id, { formId: form.id, values: { [box.id]: true }, payload: submit.payload } as never);
    expect(result).toMatchObject({ type: "sendToAgent", agent: alpha });
    expect((result as { text: string }).text).toContain("1 review comment on PR #12 (o/r)");
  });
});

describe("issues", () => {
  it("lists assigned issues in the section and spawns an agent from one", async () => {
    const stub = setup();
    stub.route("GET", ISSUES, {
      body: [{ number: 7, title: "Fix the thing", body: "details", html_url: "https://github.com/o/r/issues/7", repository: { full_name: "o/r" } }],
    });
    await stub.emit("activate", section);
    const item = itemsOf(nodes(stub.lastRender(section))[0])[0];
    expect(item.title).toBe("Fix the thing");
    expect(item.actions?.[0]).toMatchObject({ type: "spawnAgent", repo: "o/r", branch: "issue-7-fix-the-thing" });
    expect((item.actions?.[0] as { prompt: string }).prompt).toContain("details");
    noLimitProblems(stub);
  });

  it("serves the same list from the new-agent-from-issue command", async () => {
    const stub = setup();
    stub.route("GET", ISSUES, { body: [] });
    await stub.emit("command", "new-agent-from-issue", palette("new-agent-from-issue"));
    expect(titleOf(stub.lastRender(palette("new-agent-from-issue")))).toBe("No assigned issues");
  });
});

describe("commands", () => {
  it("open-pr lists mapped agents with their PR link", async () => {
    const stub = setup();
    await stub.emit("command", "open-pr", palette("open-pr"));
    const item = itemsOf(nodes(stub.lastRender(palette("open-pr")))[0])[0];
    expect(item).toMatchObject({ title: "alpha", subtitle: "#12 · o/r" });
    expect(item.actions?.[0]).toMatchObject({ type: "openURL", url: "https://github.com/o/r/pull/12" });
  });

  it("create-pr: pick, form, POST, and the 422 'push the branch' path", async () => {
    const stub = setup();
    const slot = palette("create-pr");
    stub.route("GET", API + "/repos/o/r", { body: { default_branch: "trunk" } });
    await stub.emit("command", "create-pr", slot);
    const pick = asCallback(itemsOf(nodes(stub.lastRender(slot))[0])[0].actions?.[0]);
    await stub.emit("callback", pick.id, pick.payload);
    const form = nodes(stub.lastRender(slot))[0] as Form;
    expect(form.fields.find((f) => f.id === "base")?.value).toBe("trunk");
    expect(form.fields.find((f) => f.id === "title")?.value).toBe("Feat x");

    stub.route("POST", API + "/repos/o/r/pulls", { status: 422, body: { message: "Validation Failed", errors: [{ resource: "PullRequest", field: "head", code: "invalid" }] } });
    const submit = asCallback(form.fields.find((f) => f.type === "submit")!.action);
    await stub.emit("callback", submit.id, { formId: form.id, values: { title: "Feat x", body: "", base: "trunk", draft: true }, payload: submit.payload } as never);
    const post = stub.fetches.find((f) => f.method === "POST" && f.url.endsWith("/pulls"))!;
    expect(JSON.parse(post.body!)).toEqual({ title: "Feat x", body: "", head: "feat/x", base: "trunk", draft: true });
    const root = stub.lastRender(slot);
    expect(titleOf(root)).toBe("Branch isn't pushed");
    const ask = itemsOf(nodes(root)[1])[0].actions?.[0];
    expect(ask).toMatchObject({ type: "sendToAgent", agent: alpha });
    noLimitProblems(stub);
  });

  it("sign-out deletes the token, signs every slot out and stops polling", async () => {
    const stub = setup();
    await activateAll(stub);
    await stub.emit("command", "sign-out", palette("sign-out"));
    expect(stub.secretStore.has("token")).toBe(false);
    expect(titleOf(stub.lastRender(palette("sign-out")))).toBe("Signed out");
    expect(titleOf(stub.lastRender(accessory(alpha)))).toBe("Sign in to GitHub");
    const before = stub.fetches.length;
    await stub.tick(180);
    expect(stub.fetches.length).toBe(before);
  });
});

describe("401", () => {
  it("signs every slot out, deletes the token and stops polling", async () => {
    const stub = setup();
    stub.route("GET", ISSUES, { body: [] });
    await activateAll(stub);
    await stub.emit("activate", section);
    await stub.emit("viewOpened", alpha, view(alpha));
    stub.route("GET", PULLS, asResponse(unauthorized as never));
    await stub.tick(60);
    for (const slot of [accessory(alpha), accessory(beta), view(alpha), section]) {
      expect(titleOf(stub.lastRender(slot))).toBe("Sign in to GitHub");
    }
    expect(stub.secretStore.has("token")).toBe(false);
    const before = stub.fetches.length;
    await stub.tick(180);
    expect(stub.fetches.length).toBe(before);
    noLimitProblems(stub);
  });

  it("a 401 on a user action signs out too", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, view(alpha));
    stub.route("GET", LOG, asResponse(unauthorized as never));
    const item = itemsOf(nodes(stub.lastRender(view(alpha)))[1]).find((i) => i.title === "test")!;
    const send = asCallback(item.actions?.[0]);
    const result = await stub.emit("callback", send.id, send.payload);
    expect(result ?? null).toBeNull();
    expect(titleOf(stub.lastRender(view(alpha)))).toBe("Sign in to GitHub");
  });
});

describe("rate limit", () => {
  const RESET_SEC = START_MS / 1000 + 600;
  const limited = { status: 403, headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(RESET_SEC) }, body: { message: "API rate limit exceeded" } };

  it("shows the tooltip and banner, pauses polling, and resumes after the reset", async () => {
    const stub = setup();
    await activateAll(stub);
    stub.route("GET", PULLS, limited);
    await stub.tick(60);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12", help: "Rate limited until 07:10" });

    const calls = pullFetches(stub);
    await stub.tick(300);
    expect(pullFetches(stub)).toBe(calls);

    await stub.emit("viewOpened", alpha, view(alpha));
    const root = stub.lastRender(view(alpha));
    expect(nodes(root)[0]).toMatchObject({ type: "EmptyState", title: "Rate limited until 07:10" });

    stub.route("GET", PULLS, asResponse(pullsOpen as never));
    await stub.tick(300);
    expect(stub.lastRender(accessory(alpha))).toMatchObject({ text: "#12" });
    expect((stub.lastRender(accessory(alpha)) as { help?: string }).help).toBeUndefined();
    expect(pullFetches(stub)).toBeGreaterThan(calls);
    noLimitProblems(stub);
  });
});
