import { describe, expect, it } from "vitest";
import { createPoller, CLAUDE_URL, CODEX_URL, POLL_INTERVAL_SEC } from "../src/poller";
import type { Handle } from "../src/api";
import claudeFull from "./fixtures/claude-full.json";
import codexFull from "./fixtures/codex-full.json";
import { createStubLeo } from "./stubLeo";

const claude: Handle = { id: "c1", kind: "claude-code", label: "claude-work", path: "~/.claude-work" };
const claude2: Handle = { id: "c2", kind: "claude-code", label: "claude-home", path: "~/.claude" };
const codex: Handle = { id: "x1", kind: "codex", label: ".codex", path: "~/.codex" };

const setup = (handles: Handle[]) => {
  const stub = createStubLeo();
  stub.setCredentials(handles);
  const changes: number[] = [];
  const poller = createPoller(stub.leo, stub.clock, () => changes.push(stub.clock.now()));
  return { stub, poller, changes };
};

const stateOf = (p: ReturnType<typeof createPoller>, id: string) => p.accounts().find((a) => a.handle.id === id)?.state;

describe("poller", () => {
  it("fetches each account's endpoint with its credential and parses windows", async () => {
    const { stub, poller } = setup([claude, codex]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await poller.sync();
    await poller.refresh();
    expect(stub.fetches.map((f) => [f.url, f.credential])).toEqual([[CLAUDE_URL, "c1"], [CODEX_URL, "x1"]]);
    expect(stateOf(poller, "c1")).toMatchObject({ status: "ok" });
    expect(stateOf(poller, "c1")?.windows).toHaveLength(4);
    expect(stateOf(poller, "x1")?.windows).toHaveLength(2);
  });

  it("never sends its own Authorization headers", async () => {
    const { stub, poller } = setup([claude]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    await poller.sync();
    await poller.refresh();
    expect(Object.keys(stub.fetches[0].headers).map((h) => h.toLowerCase())).not.toContain("authorization");
  });

  it("is loading before the first fetch finishes", async () => {
    const { poller } = setup([claude]);
    await poller.sync();
    expect(stateOf(poller, "c1")?.status).toBe("loading");
  });

  it("never overlaps requests, even with accounts queued and concurrent refreshes", async () => {
    const { stub, poller } = setup([claude, claude2, codex]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await poller.sync();
    await Promise.all([poller.refresh(), poller.refresh()]);
    expect(stub.maxInFlight).toBe(1);
    expect(stub.fetches).toHaveLength(3); // the second refresh joined the first
  });

  it.each([
    [{ status: 401 }, "expired"],
    [{ status: 500 }, "error"],
    [{ status: 200, body: "not json" }, "error"],
    [{ status: 200, body: {} }, "error"],
    [{ reject: "credentialNeedsAuthorization" }, "needsAuthorization"],
    [{ reject: "network down" }, "error"],
  ])("maps %j to %s", async (entry, status) => {
    const { stub, poller } = setup([claude]);
    stub.route("GET", CLAUDE_URL, entry);
    await poller.sync();
    await poller.refresh();
    expect(stateOf(poller, "c1")?.status).toBe(status);
  });

  it("goes stale, keeping values, when a later fetch fails", async () => {
    const { stub, poller } = setup([claude]);
    stub.route("GET", CLAUDE_URL, { body: claudeFull }, { status: 503 });
    await poller.sync();
    await poller.refresh();
    await poller.refresh({ force: true });
    expect(stateOf(poller, "c1")).toMatchObject({ status: "stale", message: "HTTP 503" });
    expect(stateOf(poller, "c1")?.windows).toHaveLength(4);
  });

  it("429 skips that account for 15 minutes but keeps polling the others", async () => {
    const { stub, poller } = setup([claude, codex]);
    stub.route("GET", CLAUDE_URL, { status: 429 }, { body: claudeFull });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await poller.sync();
    await poller.refresh();
    expect(stub.fetches).toHaveLength(2);
    stub.clock.advance(5 * 60_000);
    await poller.refresh();
    expect(stub.fetches.map((f) => f.credential)).toEqual(["c1", "x1", "x1"]);
    stub.clock.advance(10 * 60_000);
    await poller.refresh();
    expect(stub.fetches.filter((f) => f.credential === "c1")).toHaveLength(2);
    expect(stateOf(poller, "c1")?.status).toBe("ok");
  });

  it("a manual refresh ignores backoff", async () => {
    const { stub, poller } = setup([claude]);
    stub.route("GET", CLAUDE_URL, { status: 429 }, { body: claudeFull });
    await poller.sync();
    await poller.refresh();
    await poller.refresh({ force: true });
    expect(stateOf(poller, "c1")?.status).toBe("ok");
  });

  it("start() refreshes now and then every 5 minutes on leo.timer", async () => {
    const { stub, poller } = setup([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    await poller.start();
    expect(stub.fetches).toHaveLength(1);
    expect(POLL_INTERVAL_SEC).toBe(300);
    await stub.tick(300);
    expect(stub.fetches).toHaveLength(2);
  });

  it("notifies on every state change", async () => {
    const { stub, poller, changes } = setup([codex]);
    stub.route("GET", CODEX_URL, { body: codexFull });
    await poller.sync();
    const before = changes.length;
    await poller.refresh();
    expect(changes.length).toBeGreaterThan(before);
  });

  it("sync drops removed accounts and adds new ones, in stored order", async () => {
    const { stub, poller } = setup([claude, codex]);
    await poller.sync();
    stub.setCredentials([codex, claude2]);
    await poller.sync();
    expect(poller.accounts().map((a) => a.handle.id)).toEqual(["x1", "c2"]);
  });

  it("persists order, custom labels and last-good snapshots, and restores them", async () => {
    const first = setup([claude, codex]);
    first.stub.route("GET", CLAUDE_URL, { body: claudeFull });
    first.stub.route("GET", CODEX_URL, { body: codexFull });
    await first.poller.sync();
    await first.poller.refresh();
    await first.poller.rename("c1", "Work");
    const second = createPoller(first.stub.leo, first.stub.clock, () => {});
    await second.sync();
    const restored = second.accounts().find((a) => a.handle.id === "c1");
    expect(restored?.label).toBe("Work");
    expect(restored?.state.windows).toHaveLength(4);
    expect(restored?.state.status).toBe("ok");
  });
});
