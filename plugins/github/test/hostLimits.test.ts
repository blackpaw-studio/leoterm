import { describe, expect, it } from "vitest";
import type { AgentRef, SlotID } from "../../sdk/leo";
import { createPlugin } from "../src/plugin";
import { createStubLeo, type StubLeo } from "./stubLeo";

const API = "https://api.github.com";
const accessory = (a: AgentRef): SlotID => ({ kind: "accessory", id: "pr", agent: a });
const names = (n: number): string[] => Array.from({ length: n }, (_, i) => "agent" + i);
const ref = (name: string): AgentRef => ({ machine: "m", name });

const pullsUrl = (name: string): string => `${API}/repos/o/r/pulls?head=o:feat%2F${name}&state=open&per_page=10`;
const runsUrl = (name: string): string => `${API}/repos/o/r/commits/sha-${name}/check-runs?per_page=100`;
const statusUrl = (name: string): string => `${API}/repos/o/r/commits/sha-${name}/status`;
const run = (conclusion: string) => ({ body: { check_runs: [{ id: 1, name: "ci", status: "completed", conclusion, app: { slug: "github-actions" } }] } });

/** `n` agents, each on its own branch with an open PR whose single check is green. */
const fleet = (n: number): { stub: StubLeo; agents: AgentRef[] } => {
  const stub = createStubLeo();
  stub.secretStore.set("token", "tok");
  const agents = names(n).map(ref);
  stub.setAgents(agents.map((a) => ({ ...a, status: "idle", repo: "o/r", branch: "feat/" + a.name, hasWorktree: true })));
  agents.forEach((a, i) => {
    stub.route("GET", pullsUrl(a.name), {
      body: [{ number: i + 1, title: "t", state: "open", draft: false, updated_at: "2026-11-10T12:00:00Z", head: { sha: "sha-" + a.name, ref: "feat/" + a.name }, html_url: "https://github.com/o/r/pull/" + (i + 1) }],
    });
    stub.route("GET", runsUrl(a.name), run("success"));
    stub.route("GET", statusUrl(a.name), { body: { statuses: [] } });
  });
  createPlugin(stub.leo, stub.clock);
  return { stub, agents };
};

const chip = (stub: StubLeo, a: AgentRef): unknown => (stub.lastRender(accessory(a)) as { color?: string } | undefined)?.color;

describe("host fetch limits", () => {
  it("never gets a fetch rejected with 6 agents activating at once, and every chip draws", async () => {
    const { stub, agents } = fleet(6);
    await stub.emit("activate");
    await Promise.all(agents.map((a) => stub.emit("activate", accessory(a))));
    expect(stub.hostRejections).toEqual([]);
    expect(stub.maxInFlight).toBeLessThanOrEqual(4);
    expect(agents.map((a) => chip(stub, a))).toEqual(agents.map(() => "success"));
  });

  it("refreshes all 6 chips from the poll without a rejection", async () => {
    const { stub, agents } = fleet(6);
    await stub.emit("activate");
    await Promise.all(agents.map((a) => stub.emit("activate", accessory(a))));
    agents.forEach((a) => stub.route("GET", runsUrl(a.name), run("failure")));
    await stub.tick(60);
    expect(stub.hostRejections).toEqual([]);
    expect(stub.maxInFlight).toBeLessThanOrEqual(4);
    expect(agents.map((a) => chip(stub, a))).toEqual(agents.map(() => "failure"));
  });

  it("round-robins 16 agents through the 40/min poll budget, never touching the host limit", async () => {
    const { stub, agents } = fleet(16);
    await stub.emit("activate");
    await Promise.all(agents.map((a) => stub.emit("activate", accessory(a))));
    agents.forEach((a) => stub.route("GET", runsUrl(a.name), run("failure")));
    for (let minute = 0; minute < 3; minute++) await stub.tick(60);
    expect(stub.hostRejections).toEqual([]);
    expect(stub.maxInFlight).toBeLessThanOrEqual(4);
    expect(agents.map((a) => chip(stub, a))).toEqual(agents.map(() => "failure"));
  });

  it("Open PR over 6 agents fans out without a rejection", async () => {
    const { stub } = fleet(6);
    const slot: SlotID = { kind: "palette", commandID: "open-pr" };
    await stub.emit("command", "open-pr", slot);
    expect(stub.hostRejections).toEqual([]);
    expect(stub.maxInFlight).toBeLessThanOrEqual(4);
    const rows = (stub.lastRender(slot) as { sections: Array<{ items: Array<{ subtitle?: string }> }> }).sections[0].items;
    expect(rows.map((r) => r.subtitle)).toEqual(rows.map((_, i) => `#${i + 1} · o/r`));
  });
});
