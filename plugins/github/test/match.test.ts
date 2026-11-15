import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { findOpenPr } from "../src/pr/match";
import { asResponse } from "./fixtureLoader";
import { createStubLeo } from "./stubLeo";
import pullsOpen from "./fixtures/pulls-open.json";
import pullsEmpty from "./fixtures/pulls-empty.json";
import unauthorized from "./fixtures/401.json";

const URL = "https://api.github.com/repos/o/r/pulls?head=o:feat%2Fx&state=open&per_page=10";
const setup = () => {
  const stub = createStubLeo();
  return { stub, client: createGitHubClient(stub.leo, stub.clock) };
};

describe("findOpenPr", () => {
  it("queries head=owner:branch and takes the most recently updated PR", async () => {
    const { stub, client } = setup();
    stub.route("GET", URL, asResponse(pullsOpen as never));
    const res = await findOpenPr(client, "tok", { owner: "o", repo: "r" }, "feat/x");
    expect(res).toEqual({
      ok: true,
      value: { number: 12, title: "Newest", draft: true, htmlUrl: "https://github.com/o/r/pull/12", headSha: "bbb222", updatedAt: "2026-11-10T12:30:00Z" },
    });
  });

  it("returns null when no PR is open", async () => {
    const { stub, client } = setup();
    stub.route("GET", URL, asResponse(pullsEmpty as never));
    expect(await findOpenPr(client, "tok", { owner: "o", repo: "r" }, "feat/x")).toEqual({ ok: true, value: null });
  });

  it("skips malformed entries", async () => {
    const { stub, client } = setup();
    stub.route("GET", URL, { body: [{ number: "x" }, null, { number: 3, title: "t", head: { sha: "s" }, html_url: "https://github.com/o/r/pull/3", updated_at: "2026-01-01T00:00:00Z" }] });
    const res = await findOpenPr(client, "tok", { owner: "o", repo: "r" }, "feat/x");
    expect(res).toMatchObject({ ok: true, value: { number: 3, draft: false } });
  });

  it("propagates classified errors", async () => {
    const { stub, client } = setup();
    stub.route("GET", URL, asResponse(unauthorized as never));
    expect(await findOpenPr(client, "tok", { owner: "o", repo: "r" }, "feat/x")).toEqual({ ok: false, error: { kind: "Unauthorized" } });
  });
});
