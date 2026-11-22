import { describe, expect, it } from "vitest";
import { createPlugin } from "../src/plugin";
import { CLAUDE_URL, CODEX_URL } from "../src/poller";
import type { GroupNode, Handle } from "../src/api";
import type { SlotID } from "../../sdk/leo";
import claudeFull from "./fixtures/claude-full.json";
import claudePartial from "./fixtures/claude-partial.json";
import codexFull from "./fixtures/codex-full.json";
import { createStubLeo } from "./stubLeo";

const SECTION: SlotID = { kind: "section", id: "usage" };
const SHOW: SlotID = { kind: "palette", commandID: "show" };

const work: Handle = { id: "c1", kind: "claude-code", label: ".claude-work", path: "~/.claude-work" };
const home: Handle = { id: "c2", kind: "claude-code", label: ".claude", path: "~/.claude" };
const old: Handle = { id: "c3", kind: "claude-code", label: ".claude-old", path: "~/.claude-old" };
const codex: Handle = { id: "x1", kind: "codex", label: ".codex", path: "~/.codex" };

const boot = () => {
  const stub = createStubLeo();
  createPlugin(stub.leo, stub.clock);
  return stub;
};

const groupsOf = (tree: unknown): GroupNode[] => (Array.isArray(tree) ? tree : [tree]).filter((n) => n?.type === "Group");
const json = (tree: unknown): string => JSON.stringify(tree, null, 2) + "\n";

describe("sidebar", () => {
  it("shows the empty state with add actions before any account is granted", async () => {
    const stub = boot();
    await stub.emit("activate", SECTION);
    expect(stub.lastRender(SECTION)).toMatchObject({ type: "EmptyState" });
  });

  it("renders 3 Claude + 1 Codex accounts (sidebar tree fixture)", async () => {
    const stub = boot();
    stub.setCredentials([work, home, old, codex]);
    // One claude route cannot serve three accounts differently, so use the credential-agnostic URL in order.
    stub.route("GET", CLAUDE_URL, { body: claudeFull }, { body: claudePartial }, { status: 401 });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    const tree = stub.lastRender(SECTION);
    expect(groupsOf(tree).map((g) => g.title)).toEqual(["claude-work", "claude", "claude-old", "codex"]);
    await expect(json(tree)).toMatchFileSnapshot("./fixtures/trees/sidebar.json");
  });

  it("re-polls every five minutes and redraws", async () => {
    const stub = boot();
    stub.setCredentials([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    const before = stub.rendersFor(SECTION).length;
    await stub.tick(300);
    expect(stub.fetches).toHaveLength(2);
    expect(stub.rendersFor(SECTION).length).toBeGreaterThan(before);
  });
});

describe("Show Account Usage", () => {
  it("renders every window for all accounts (full tree fixture)", async () => {
    const stub = boot();
    stub.setCredentials([work, home, old, codex]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull }, { body: claudePartial }, { status: 401 });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    await stub.emit("command", "show", SHOW);
    const tree = stub.lastRender(SHOW);
    expect(groupsOf(tree)[0].children.filter((c) => c.type === "Meter")).toHaveLength(4);
    await expect(json(tree)).toMatchFileSnapshot("./fixtures/trees/full.json");
  });

  it("keeps the palette page live when state changes", async () => {
    const stub = boot();
    stub.setCredentials([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    await stub.emit("command", "show", SHOW);
    const before = stub.rendersFor(SHOW).length;
    await stub.tick(300);
    expect(stub.rendersFor(SHOW).length).toBeGreaterThan(before);
  });
});

describe("adding accounts", () => {
  it.each([
    ["add-claude", "claude-code", work, CLAUDE_URL, claudeFull],
    ["add-codex", "codex", codex, CODEX_URL, codexFull],
  ] as const)("%s command asks the host synchronously, then polls the new account", async (command, kind, handle, url, body) => {
    const stub = boot();
    stub.queueAdd(kind, handle);
    stub.route("GET", url, { body });
    await stub.emit("activate", SECTION);
    await stub.emit("command", command, { kind: "palette", commandID: command });
    expect(stub.credentialCalls).toContain("add:" + kind); // the stub rejects gestureRequired after any await
    expect(stub.fetches.map((f) => f.credential)).toEqual([handle.id]);
    expect(groupsOf(stub.lastRender(SECTION)).map((g) => g.title)).toEqual([handle.label.replace(/^\./, "")]);
  });

  it("the sidebar's Add Account callbacks also add synchronously", async () => {
    const stub = boot();
    stub.queueAdd("codex", codex);
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    await stub.emit("callback", "add", { kind: "codex" });
    expect(stub.credentialCalls).toContain("add:codex");
    expect(groupsOf(stub.lastRender(SECTION))).toHaveLength(1);
  });

  it("a cancelled panel changes nothing and says so in the palette", async () => {
    const stub = boot();
    stub.queueAdd("claude-code", null);
    await stub.emit("activate", SECTION);
    const slot: SlotID = { kind: "palette", commandID: "add-claude" };
    await stub.emit("command", "add-claude", slot);
    expect(stub.fetches).toHaveLength(0);
    expect(stub.lastRender(slot)).toMatchObject({ type: "EmptyState", title: "No account added" });
  });

  it("ignores a malformed add payload without calling the host", async () => {
    const stub = boot();
    await stub.emit("activate", SECTION);
    await stub.emit("callback", "add", { kind: "bogus" });
    expect(stub.credentialCalls.filter((c) => c.startsWith("add"))).toEqual([]);
  });
});

describe("account actions", () => {
  const withLocked = async () => {
    const stub = boot();
    stub.setCredentials([work]);
    stub.route("GET", CLAUDE_URL, { reject: "credentialNeedsAuthorization" }, { body: claudeFull });
    await stub.emit("activate", SECTION);
    return stub;
  };

  it("shows Locked, and Grant Access calls authorize synchronously then retries", async () => {
    const stub = await withLocked();
    expect(groupsOf(stub.lastRender(SECTION))[0].accessory).toMatchObject({ text: "Locked" });
    await stub.emit("callback", "authorize", { id: "c1" });
    expect(stub.credentialCalls).toContain("authorize:c1");
    expect(groupsOf(stub.lastRender(SECTION))[0].accessory).toBeUndefined();
  });

  it("a refused authorization is logged and the account stays locked", async () => {
    const stub = await withLocked();
    stub.failAuthorize("gestureRequired");
    await stub.emit("callback", "authorize", { id: "c1" });
    expect(stub.logs.some((l) => l.level === "error" && l.message.includes("gestureRequired"))).toBe(true);
    expect(groupsOf(stub.lastRender(SECTION))[0].accessory).toMatchObject({ text: "Locked" });
  });

  it("Refresh Usage forces a poll even during a 429 backoff", async () => {
    const stub = boot();
    stub.setCredentials([work]);
    stub.route("GET", CLAUDE_URL, { status: 429 }, { body: claudeFull });
    await stub.emit("activate", SECTION);
    await stub.emit("command", "refresh", { kind: "palette", commandID: "refresh" });
    expect(stub.fetches).toHaveLength(2);
  });

  it("Remove drops the grant and the account", async () => {
    const stub = boot();
    stub.setCredentials([work, codex]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", SECTION);
    await stub.emit("callback", "remove", { id: "c1" });
    expect(stub.credentialCalls).toContain("remove:c1");
    expect(groupsOf(stub.lastRender(SECTION)).map((g) => g.title)).toEqual(["codex"]);
  });

  it("Rename submits the form value as the account's label", async () => {
    const stub = boot();
    stub.setCredentials([work]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    await stub.emit("activate", SECTION);
    await stub.emit("callback", "rename", { formId: "rename", values: { label: "Work" }, payload: { id: "c1" } });
    expect(groupsOf(stub.lastRender(SECTION))[0].title).toBe("Work");
  });
});

describe("startup recovery", () => {
  it("a failed first start is retried by the next activate, with one timer only", async () => {
    const stub = boot();
    stub.setCredentials([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    stub.failNextList("host not ready");
    await stub.emit("activate", SECTION);
    expect(stub.logs.some((l) => l.level === "error" && l.message.includes("host not ready"))).toBe(true);
    expect(stub.fetches).toHaveLength(0);
    await stub.emit("activate", SECTION);
    expect(stub.fetches).toHaveLength(1);
    await stub.tick(300);
    expect(stub.fetches).toHaveLength(2); // a single timer, not one per attempt
  });

  it("the poll timer is registered even when the first pass fails, and recovers on its tick", async () => {
    const stub = boot();
    stub.setCredentials([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    stub.failNextList("host not ready");
    await stub.emit("activate", SECTION);
    await stub.tick(300);
    expect(stub.fetches).toHaveLength(1);
    expect(groupsOf(stub.lastRender(SECTION))).toHaveLength(1);
  });
});
