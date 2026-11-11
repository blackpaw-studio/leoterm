import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { combineState, fetchChecks, findCheck, type CheckItem } from "../src/pr/checks";
import { accessoryRoot, formatResetTime } from "../src/ui/accessory";
import { asResponse } from "./fixtureLoader";
import { createStubLeo } from "./stubLeo";
import runsMixed from "./fixtures/check-runs-mixed.json";
import runsEmpty from "./fixtures/check-runs-empty.json";
import statusPending from "./fixtures/status-pending.json";
import statusEmpty from "./fixtures/status-empty.json";

const REF = { owner: "o", repo: "r" };
const RUNS = "https://api.github.com/repos/o/r/commits/abc/check-runs?per_page=100";
const STATUS = "https://api.github.com/repos/o/r/commits/abc/status";
const item = (state: CheckItem["state"]): CheckItem => ({ id: "x", name: "n", state, url: null, source: "actions", jobId: 1 });
const setup = () => {
  const stub = createStubLeo();
  return { stub, client: createGitHubClient(stub.leo, stub.clock) };
};

describe("combineState", () => {
  it.each([
    [[], "neutral"],
    [["success", "success"], "success"],
    [["success", "neutral"], "success"],
    [["success", "running"], "running"],
    [["running", "failure", "success"], "failure"],
    [["neutral"], "neutral"],
  ] as const)("%j → %s", (states, want) => expect(combineState(states.map(item))).toBe(want));
});

describe("fetchChecks", () => {
  it("maps run conclusions and statuses, and combines mixed results to failure", async () => {
    const { stub, client } = setup();
    stub.route("GET", RUNS, asResponse(runsMixed as never));
    stub.route("GET", STATUS, asResponse(statusPending as never));
    const res = await fetchChecks(client, "tok", REF, "abc");
    if (!res.ok) throw new Error("expected ok");
    const byName = Object.fromEntries(res.value.map((c) => [c.name, c.state]));
    expect(byName).toEqual({ build: "success", test: "failure", lint: "running", docs: "success", codecov: "success", "ci/legacy": "running", "ci/other": "success" });
    expect(combineState(res.value)).toBe("failure");
    expect(res.value.find((c) => c.name === "test")).toMatchObject({ id: "9002", source: "actions", jobId: 9002 });
    expect(res.value.find((c) => c.name === "codecov")).toMatchObject({ source: "other", jobId: null });
    expect(res.value.find((c) => c.name === "ci/legacy")).toMatchObject({ id: "status:71", source: "status", url: "https://ci.example.com/71" });
  });

  it("collapses same-named runs from one head SHA (push + pull_request) to one row, the newest run when states match", async () => {
    const { stub, client } = setup();
    const run = (id: number, name: string, conclusion: string) => ({ id, name, status: "completed", conclusion, app: { slug: "github-actions" } });
    stub.route("GET", RUNS, { body: { check_runs: [run(10, "lint", "success"), run(12, "lint", "success"), run(11, "test", "success"), run(13, "test", "success")] } });
    stub.route("GET", STATUS, asResponse(statusEmpty as never));
    const res = await fetchChecks(client, "tok", REF, "abc");
    if (!res.ok) throw new Error("expected ok");
    expect(res.value.map((c) => [c.name, c.id])).toEqual([["lint", "12"], ["test", "13"]]);
    expect(combineState(res.value)).toBe("success");
  });

  it("keeps a failing push run visible when the newer pull_request run of the same name passes", async () => {
    const { stub, client } = setup();
    const run = (id: number, name: string, conclusion: string) => ({ id, name, status: "completed", conclusion, app: { slug: "github-actions" } });
    stub.route("GET", RUNS, { body: { check_runs: [run(10, "test", "failure"), run(12, "test", "success")] } });
    stub.route("GET", STATUS, asResponse(statusEmpty as never));
    const res = await fetchChecks(client, "tok", REF, "abc");
    if (!res.ok) throw new Error("expected ok");
    expect(combineState(res.value)).toBe("failure");
    expect(res.value.map((c) => [c.name, c.id, c.state])).toEqual([["test", "10", "failure"]]);
  });

  it.each(["failure", "timed_out", "cancelled", "action_required", "startup_failure"])("treats conclusion %s as failure", async (conclusion) => {
    const { stub, client } = setup();
    stub.route("GET", RUNS, { body: { check_runs: [{ id: 1, name: "a", status: "completed", conclusion }] } });
    stub.route("GET", STATUS, asResponse(statusEmpty as never));
    const res = await fetchChecks(client, "tok", REF, "abc");
    expect(res.ok && combineState(res.value)).toBe("failure");
  });

  it("treats failure and error statuses as failure", async () => {
    const { stub, client } = setup();
    stub.route("GET", RUNS, asResponse(runsEmpty as never));
    stub.route("GET", STATUS, { body: { total_count: 2, statuses: [{ id: 1, context: "a", state: "error" }, { id: 2, context: "b", state: "success" }] } });
    const res = await fetchChecks(client, "tok", REF, "abc");
    expect(res.ok && combineState(res.value)).toBe("failure");
  });

  it("is neutral with no checks (an empty combined status does not count as pending)", async () => {
    const { stub, client } = setup();
    stub.route("GET", RUNS, asResponse(runsEmpty as never));
    stub.route("GET", STATUS, asResponse(statusEmpty as never));
    const res = await fetchChecks(client, "tok", REF, "abc");
    expect(res).toEqual({ ok: true, value: [] });
  });

  it("returns the first error", async () => {
    const { stub, client } = setup();
    stub.route("GET", RUNS, { reject: "offline" });
    stub.route("GET", STATUS, asResponse(statusEmpty as never));
    expect(await fetchChecks(client, "tok", REF, "abc")).toMatchObject({ ok: false, error: { kind: "Transport" } });
  });

  it("findCheck looks up by id", () => {
    const checks = [item("failure")];
    expect(findCheck(checks, "x")).toBe(checks[0]);
    expect(findCheck(checks, "nope")).toBeUndefined();
  });
});

describe("accessoryRoot", () => {
  it.each([
    ["success", "checkmark.circle.fill"],
    ["failure", "xmark.circle.fill"],
    ["running", "arrow.triangle.2.circlepath"],
    ["neutral", "arrow.triangle.pull"],
  ] as const)("%s chip uses %s", (state, sfSymbol) => {
    expect(accessoryRoot({ kind: "pr", number: 123, state })).toEqual({ type: "Accessory", text: "#123", sfSymbol, color: state });
  });

  it("clamps the number text to 8 characters", () => {
    expect(accessoryRoot({ kind: "pr", number: 12345678, state: "success" })).toMatchObject({ text: "#1234567" });
  });

  it("shows 'no PR' for a mapped agent without a PR", () => {
    expect(accessoryRoot({ kind: "noPr" })).toEqual({ type: "Accessory", text: "no PR", color: "neutral" });
  });

  it("draws nothing when hidden (unmapped or signed out)", () => {
    expect(accessoryRoot({ kind: "hidden" })).toEqual([]);
  });

  it("keeps the last chip and adds rate-limit help; hidden stays hidden", () => {
    const until = new Date(2026, 10, 11, 9, 5).getTime();
    expect(accessoryRoot({ kind: "pr", number: 5, state: "running" }, until)).toMatchObject({ text: "#5", help: "Rate limited until 09:05" });
    expect(accessoryRoot({ kind: "hidden" }, until)).toEqual([]);
  });

  it("formats reset time as zero-padded local HH:MM", () => {
    expect(formatResetTime(new Date(2026, 0, 2, 0, 7).getTime())).toBe("00:07");
    expect(formatResetTime(new Date(2026, 0, 2, 23, 59).getTime())).toBe("23:59");
    // fixed TZ America/New_York: 1767268800 = 2026-01-01T12:00:00Z = 07:00 EST
    expect(formatResetTime(1767268800 * 1000)).toBe("07:00");
  });
});
