import { describe, expect, it } from "vitest";
import type { AgentRef, AgentSnapshot, Node, PaneSlot, Text, UsageSnapshot } from "../../sdk/leo";
import { createPlugin } from "../src/plugin";
import { createStubLeo, START_MS } from "./stubLeo";

const alpha: AgentRef = { machine: "Mac", name: "alpha" };
const beta: AgentRef = { machine: "Mac", name: "beta" };
const slot = (agent: AgentRef, part: "summary" | "body"): PaneSlot => ({ kind: "pane", id: "status", part, agent });

const snapshot = (agent: AgentRef, extra: Partial<AgentSnapshot> = {}): AgentSnapshot => ({
  name: agent.name,
  machine: agent.machine,
  status: "running",
  repo: null,
  branch: "main",
  hasWorktree: false,
  workspace: "~/.leo/agents/" + agent.name,
  ...extra,
});

const usage = (percent: number, resetMs?: number): UsageSnapshot => ({
  model: "Opus 5.5",
  context: { tokens: percent * 1000, window: 100_000, percent },
  ...(resetMs === undefined ? {} : { rateLimits: [{ kind: "five_hour", percentUsed: 3, resetsAt: new Date(START_MS + resetMs).toISOString() }] }),
});

const texts = (tree: unknown): string[] => {
  const nodes = (Array.isArray(tree) ? tree : [tree]) as Node[];
  return nodes.filter((n): n is Text => n.type === "Text").map((n) => n.runs.map((r) => r.text).join(""));
};

const setup = () => {
  const stub = createStubLeo();
  stub.setAgents([snapshot(alpha), snapshot(beta)]);
  createPlugin(stub.leo, stub.clock);
  return stub;
};

describe("status plugin", () => {
  it("renders summary and body when a pane slot opens", async () => {
    const stub = setup();
    stub.setUsage(alpha, usage(21));
    await stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    await stub.emit("viewOpened", alpha, slot(alpha, "body"));
    expect(texts(stub.lastRender(slot(alpha, "summary")))[0]).toBe("Opus 5.5");
    const body = texts(stub.lastRender(slot(alpha, "body")));
    expect(body).toContain("where    ~/.l/a/alpha · main");
    expect(body).toContain("context  ");
  });

  it("shows the empty summary while usage is null", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    expect(texts(stub.lastRender(slot(alpha, "summary")))).toEqual(["—"]);
  });

  it("ignores other slot kinds and other panes", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, { kind: "view", viewID: "x", agent: alpha });
    await stub.emit("viewOpened", alpha, { ...slot(alpha, "summary"), id: "other" });
    expect(stub.renders).toEqual([]);
    expect(stub.usageReads).toEqual([]);
  });

  it("re-renders on usageChanged only for agents it holds slots for", async () => {
    const stub = setup();
    await stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    stub.setUsage(alpha, usage(50));
    await stub.emit("usageChanged", alpha);
    expect(texts(stub.lastRender(slot(alpha, "summary")))).toEqual(["Opus 5.5", "50%"]);
    const reads = stub.usageReads.length;
    await stub.emit("usageChanged", beta);
    expect(stub.usageReads.length).toBe(reads);
  });

  it("keeps agents separate", async () => {
    const stub = setup();
    stub.setUsage(alpha, usage(10));
    stub.setUsage(beta, usage(90));
    await stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    await stub.emit("viewOpened", beta, slot(beta, "summary"));
    expect(texts(stub.lastRender(slot(alpha, "summary")))[1]).toBe("10%");
    expect(texts(stub.lastRender(slot(beta, "summary")))[1]).toBe("90%");
  });

  it("ticks the reset countdown through after(60) without re-reading usage", async () => {
    const stub = setup();
    stub.setUsage(alpha, usage(21, 3 * 3_600_000 + 50 * 60_000));
    await stub.emit("viewOpened", alpha, slot(alpha, "body"));
    expect(texts(stub.lastRender(slot(alpha, "body"))).some((l) => l.includes("session 3.0% resets 3h 50m"))).toBe(true);
    const reads = stub.usageReads.length;
    await stub.tick(60);
    expect(texts(stub.lastRender(slot(alpha, "body"))).some((l) => l.includes("session 3.0% resets 3h 49m"))).toBe(true);
    await stub.tick(60);
    expect(texts(stub.lastRender(slot(alpha, "body"))).some((l) => l.includes("session 3.0% resets 3h 48m"))).toBe(true);
    expect(stub.usageReads.length).toBe(reads);
  });

  it("does not stack timers when refreshed repeatedly", async () => {
    const stub = setup();
    stub.setUsage(alpha, usage(21, 3_600_000));
    await stub.emit("viewOpened", alpha, slot(alpha, "body"));
    await stub.emit("usageChanged", alpha);
    await stub.emit("usageChanged", alpha);
    const before = stub.renders.length;
    await stub.tick(60);
    expect(stub.renders.length - before).toBe(1);
  });

  it("falls back to usage-only rows when the agent list has no match", async () => {
    const stub = createStubLeo();
    createPlugin(stub.leo, stub.clock);
    stub.setUsage(alpha, usage(21));
    await stub.emit("viewOpened", alpha, slot(alpha, "body"));
    expect(texts(stub.lastRender(slot(alpha, "body"))).some((t) => t.startsWith("Where"))).toBe(false);
  });

  it("renders a notice and logs when usage is denied", async () => {
    const stub = setup();
    stub.denyUsage();
    await stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    expect(texts(stub.lastRender(slot(alpha, "summary")))).toEqual(["Usage unavailable"]);
    expect(stub.logs.some((l) => l.level === "error")).toBe(true);
  });

  it("drops a stale read that resolves after a newer one", async () => {
    const stub = setup();
    let release: (u: UsageSnapshot | null) => void = () => undefined;
    const slow = new Promise<UsageSnapshot | null>((r) => (release = r));
    const original = stub.leo.agents.usage;
    let calls = 0;
    stub.leo.agents.usage = (a) => (++calls === 1 ? slow : original(a));
    stub.setUsage(alpha, usage(70));
    const first = stub.emit("viewOpened", alpha, slot(alpha, "summary"));
    await stub.emit("usageChanged", alpha);
    release(usage(5));
    await first;
    expect(texts(stub.lastRender(slot(alpha, "summary")))[1]).toBe("70%");
  });
});
