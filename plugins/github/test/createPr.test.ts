import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import {
  CREATE_PR_PICK,
  CREATE_PR_SUBMIT,
  humaniseBranch,
  pickCreatePr,
  submitCreatePr,
  type CreatePrDeps,
} from "../src/pr/createPr";
import { createPrForm, createPrPicker, mappedAgents, openPrPicker } from "../src/ui/prForms";
import type { ParseRepo } from "../src/repoTypes";
import type { AgentSnapshot, Form, JSONValue, Node, SlotID } from "../../sdk/leo";
import { createStubLeo } from "./stubLeo";

const API = "https://api.github.com";
const parseRepo: ParseRepo = (raw) => {
  const m = /^([^/\s]+)\/([^/\s]+)$/.exec(raw);
  return m ? { owner: m[1], repo: m[2] } : null;
};
const agent = (name: string, repo: string | null, branch: string | null): AgentSnapshot => ({ name, machine: "m", status: "idle", repo, branch, hasWorktree: true });
const slot: SlotID = { kind: "palette", commandID: "create-pr" };
const ref = { machine: "m", name: "a1" };
const payload = { agent: ref, slot, owner: "o", repo: "r", branch: "feat/add-thing_now" };

const setup = () => {
  const stub = createStubLeo();
  const deps: CreatePrDeps = { leo: stub.leo, client: createGitHubClient(stub.leo, stub.clock), auth: "tok" };
  return { stub, deps };
};
const nodesOf = (tree: ReturnType<ReturnType<typeof createStubLeo>["lastRender"]>): Node[] => (Array.isArray(tree) ? tree : tree ? [tree] : []);
const formOf = (stub: ReturnType<typeof createStubLeo>): Form => {
  const f = nodesOf(stub.lastRender(slot)).find((n): n is Form => n.type === "Form");
  if (!f) throw new Error("no form rendered");
  return f;
};
const values = { title: "T", body: "B", base: "main", draft: true };

describe("humaniseBranch", () => {
  it.each([
    ["feat/add-thing_now", "Feat add thing now"],
    ["issue-7-fix-it", "Issue 7 fix it"],
    ["--x--", "X"],
    ["", ""],
  ])("%j → %j", (b, t) => expect(humaniseBranch(b)).toBe(t));
});

describe("pickers", () => {
  const agents = [agent("a1", "o/r", "b"), agent("a2", "/path", "b"), agent("a3", "o/r", null)];
  it("mappedAgents keeps agents with a parseable repo and a branch", () => {
    expect(mappedAgents(agents, parseRepo).map((e) => e.agent.name)).toEqual(["a1"]);
  });
  it("open-pr items open the PR url, or show 'No open PR'", () => {
    const entries = mappedAgents([agent("a1", "o/r", "b"), agent("a4", "o/x", "c")], parseRepo);
    const tree = openPrPicker(entries, new Map([["a1", { number: 3, url: "https://github.com/o/r/pull/3" }]]));
    const [withPr, without] = tree.sections[0].items;
    expect(withPr.actions?.[0]).toMatchObject({ type: "openURL", url: "https://github.com/o/r/pull/3" });
    expect(without.subtitle).toBe("No open PR");
    expect(without.actions ?? []).toEqual([]);
  });
  it("create-pr items carry agent, slot and repo coordinates in a pick callback", () => {
    const tree = createPrPicker(mappedAgents(agents, parseRepo), slot);
    expect(tree.sections[0].items[0].actions?.[0]).toMatchObject({
      type: "callback",
      id: CREATE_PR_PICK,
      payload: { agent: { machine: "m", name: "a1" }, slot, owner: "o", repo: "r", branch: expect.any(String) },
    });
  });
});

describe("createPrForm", () => {
  it("prefills a humanised title, the default base and draft on", () => {
    const form = createPrForm({ ...payload, defaultBase: "main" });
    const byId = Object.fromEntries(form.fields.map((f) => [f.id, f]));
    expect(byId.title.value).toBe("Feat add thing now");
    expect(byId.base.value).toBe("main");
    expect(byId.draft).toMatchObject({ type: "checkbox", checked: true });
    expect(byId.submit.action).toMatchObject({ type: "callback", id: CREATE_PR_SUBMIT, payload: { owner: "o", repo: "r", branch: payload.branch } });
  });
});

describe("pickCreatePr", () => {
  it("fetches default_branch and renders the form into the carried slot", async () => {
    const { stub, deps } = setup();
    stub.route("GET", `${API}/repos/o/r`, { body: { default_branch: "trunk" } });
    await pickCreatePr(deps, payload as unknown as JSONValue);
    expect(formOf(stub).fields.find((f) => f.id === "base")?.value).toBe("trunk");
  });
  it("renders an error when the repo lookup fails", async () => {
    const { stub, deps } = setup();
    stub.route("GET", `${API}/repos/o/r`, { status: 404, body: {} });
    await pickCreatePr(deps, payload as unknown as JSONValue);
    expect(JSON.stringify(stub.lastRender(slot))).toContain("Error");
  });
  it("ignores a malformed payload", async () => {
    const { stub, deps } = setup();
    await pickCreatePr(deps, { nope: 1 });
    expect(stub.renders).toEqual([]);
  });
});

describe("submitCreatePr", () => {
  const submit = (deps: CreatePrDeps, v: Record<string, JSONValue> = values) =>
    submitCreatePr(deps, { formId: "create-pr", values: v, payload } as unknown as JSONValue);

  it("POSTs the pull with head/base/draft, renders Created and follows up with openURL", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 201, body: { number: 9, html_url: "https://github.com/o/r/pull/9" } });
    const follow = await submit(deps);
    expect(JSON.parse(stub.fetches[0].body ?? "")).toEqual({ title: "T", body: "B", head: payload.branch, base: "main", draft: true });
    expect(JSON.stringify(stub.lastRender(slot))).toContain("Created #9");
    expect(follow).toMatchObject({ type: "openURL", url: "https://github.com/o/r/pull/9" });
  });

  it("treats a head-field 422 as 'Branch isn't pushed' with an Ask Agent to Push item", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 422, body: { message: "Validation Failed", errors: [{ resource: "PullRequest", field: "head", code: "invalid" }] } });
    expect(await submit(deps)).toBeUndefined();
    const text = JSON.stringify(stub.lastRender(slot));
    expect(text).toContain("Branch isn't pushed");
    expect(text).toContain("Ask Agent to Push");
    expect(text).toContain(`Please push branch ${payload.branch} to origin so I can open a PR.`);
    expect(text).toContain('"type":"sendToAgent"');
  });

  it("treats 'No commits between' as not pushed", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 422, body: { message: "No commits between main and feat" } });
    await submit(deps);
    expect(JSON.stringify(stub.lastRender(slot))).toContain("Branch isn't pushed");
  });

  it("shows any other 422 message inline, keeping the form", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 422, body: { message: "A pull request already exists for o:feat." } });
    await submit(deps);
    expect(JSON.stringify(stub.lastRender(slot))).toContain("A pull request already exists for o:feat.");
    expect(formOf(stub).fields.find((f) => f.id === "title")?.value).toBe("T");
  });

  it("renders an Unauthorized failure as a sign-in message", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 401, body: {} });
    await submit(deps);
    expect(JSON.stringify(stub.lastRender(slot))).toContain("Sign in");
  });

  it("falls back to the head field name only when 422 errors say so, not for other fields", async () => {
    const { stub, deps } = setup();
    stub.route("POST", `${API}/repos/o/r/pulls`, { status: 422, body: { message: "Validation Failed", errors: [{ field: "base", code: "invalid" }] } });
    await submit(deps);
    expect(JSON.stringify(stub.lastRender(slot))).not.toContain("Branch isn't pushed");
  });
});
