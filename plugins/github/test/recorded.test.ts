import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { combineState, fetchChecks } from "../src/pr/checks";
import { findOpenPr } from "../src/pr/match";
import { sendFailure } from "../src/pr/sendFailure";
import { fetchReviewThreads } from "../src/reviews/threads";
import { asResponse } from "./fixtureLoader";
import { createStubLeo } from "./stubLeo";
import checkRuns from "./fixtures/recorded/check-runs.json";
import logProbe from "./fixtures/recorded/job-log-206-probe.json";
import logTail from "./fixtures/recorded/job-log-206-tail.json";
import logWhole from "./fixtures/recorded/job-log-whole.json";
import notModified from "./fixtures/recorded/304.json";
import pullsEmpty from "./fixtures/pulls-empty.json";
import pullsOpen from "./fixtures/recorded/pulls-open.json";
import reviewThreads from "./fixtures/recorded/review-threads.json";
import status from "./fixtures/recorded/status.json";
import unauthorized from "./fixtures/401.json";

// Contract tests: responses recorded from the scratch repo, run through the real parsers.
// See fixtures/recorded/README.md.
const REPO = { owner: "blackpaw-studio", repo: "leo-github-plugin-scratch" };
const API = "https://api.github.com/repos/blackpaw-studio/leo-github-plugin-scratch";
const SHA = checkRuns.body.check_runs[0].head_sha;
const setup = () => {
  const stub = createStubLeo();
  return { stub, client: createGitHubClient(stub.leo, stub.clock) };
};

describe("recorded responses", () => {
  it("finds the open PR for the branch", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/pulls?head=blackpaw-studio:feat%2Fsample&state=open&per_page=10", asResponse(pullsOpen as never));
    const res = await findOpenPr(client, "tok", REPO, "feat/sample");
    expect(res).toMatchObject({ ok: true, value: { number: 1, title: "Sample change", draft: false, headSha: SHA } });
  });

  it("finds no PR for a branch without one", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/pulls?head=blackpaw-studio:feat%2Fnone&state=open&per_page=10", asResponse(pullsEmpty as never));
    expect(await findOpenPr(client, "tok", REPO, "feat/none")).toEqual({ ok: true, value: null });
  });

  it("reads Actions check runs (with their job ids), collapsing the push/pull_request duplicates, and an empty commit status; one failing run fails the PR", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/commits/" + SHA + "/check-runs?per_page=100", asResponse(checkRuns as never));
    stub.route("GET", API + "/commits/" + SHA + "/status", asResponse(status as never));
    const res = await fetchChecks(client, "tok", REPO, SHA);
    if (!res.ok) throw new Error("fetchChecks failed");
    expect(res.value.map((c) => [c.name, c.state, c.source])).toEqual([
      ["lint", "success", "actions"],
    ]);
    expect(res.value.every((c) => c.jobId !== null)).toBe(true);
    expect(combineState(res.value)).toBe("failure");
  });

  it("reads the unresolved review thread from the GraphQL response", async () => {
    const { stub, client } = setup();
    stub.route("POST", "https://api.github.com/graphql", asResponse(reviewThreads as never));
    const res = await fetchReviewThreads(client, "tok", REPO, 1);
    expect(res).toMatchObject({ ok: true, value: { reviewDecision: null, threads: [{ path: "sample.txt", line: 2, author: "scratch-user", isOutdated: false }] } });
  });

  it("classifies the 401 for a bad token", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/pulls", asResponse(unauthorized as never));
    expect(await client.request("GET", "/repos/blackpaw-studio/leo-github-plugin-scratch/pulls", { auth: "tok" })).toEqual({ ok: false, error: { kind: "Unauthorized" } });
  });

  it("replays the recorded ETag and serves the cached body on the recorded 304", async () => {
    const { stub, client } = setup();
    const url = API + "/pulls?head=blackpaw-studio:feat%2Fsample&state=open&per_page=10";
    stub.route("GET", url, asResponse(pullsOpen as never), asResponse(notModified as never));
    const path = "/repos/blackpaw-studio/leo-github-plugin-scratch/pulls?head=blackpaw-studio:feat%2Fsample&state=open&per_page=10";
    await client.getCached(path, { auth: "tok" });
    const second = await client.getCached(path, { auth: "tok" });
    expect(second).toMatchObject({ ok: true, value: { fresh: false, status: 200 } });
    expect(stub.fetches[1].headers["If-None-Match"]).toBe(pullsOpen.headers.etag);
  });

  describe("send failure", () => {
    const LOG = API + "/actions/jobs/9/logs";
    const failing = { id: "9", name: "test", state: "failure" as const, url: null, source: "actions" as const, jobId: 9 };
    const agent = { machine: "localhost", name: "a" };
    const run = (stub: ReturnType<typeof setup>["stub"], client: ReturnType<typeof setup>["client"]) =>
      sendFailure(client, "tok", { agent, repo: REPO, branch: "feat/sample", prNumber: 1, check: failing });
    const text = (res: Awaited<ReturnType<typeof run>>): string => (res.ok && res.value.type === "sendToAgent" ? res.value.text : "");

    it("excerpts the whole recorded log when the host answers the probe with a 200", async () => {
      const { stub, client } = setup();
      stub.route("GET", LOG, asResponse(logWhole as never));
      const body = text(await run(stub, client));
      expect(body).toContain("FAIL: expected 2 but got 3 (scratch fixture)");
      expect(body).not.toContain("\r");
      expect(body).not.toContain("﻿");
    });

    it("probes with bytes=0-0, then asks for bytes=N- and drops the partial first line of the recorded 206 tail", async () => {
      const { stub, client } = setup();
      stub.route("GET", LOG, asResponse(logProbe as never), asResponse(logTail as never));
      const body = text(await run(stub, client));
      expect(stub.fetches.map((f) => f.headers.Range)).toEqual(["bytes=0-0", "bytes=446509-"]);
      expect(body).toContain("line 4994");
      expect(body).not.toContain("11-11T17:53:18.9673081Z");
    });
  });
});
