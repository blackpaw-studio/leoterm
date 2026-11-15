import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { fetchReviewThreads } from "../src/reviews/threads";
import { asResponse } from "./fixtureLoader";
import { createStubLeo } from "./stubLeo";
import page1 from "./fixtures/review-threads-page1.json";
import page2 from "./fixtures/review-threads-page2.json";
import gqlErrors from "./fixtures/graphql-errors.json";
import rateLimited from "./fixtures/403-ratelimit.json";

const GQL = "https://api.github.com/graphql";
const REF = { owner: "o", repo: "r" };
const setup = () => {
  const stub = createStubLeo();
  return { stub, client: createGitHubClient(stub.leo, stub.clock) };
};

describe("fetchReviewThreads", () => {
  it("follows pagination and drops resolved threads", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(page1), asResponse(page2));
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    expect(res.ok && res.value.threads.map((t) => t.id)).toEqual(["T1", "T3", "T4"]);
    expect(stub.fetches).toHaveLength(2);
    expect(JSON.parse(stub.fetches[1].body!).variables).toMatchObject({ owner: "o", name: "r", number: 12, after: "CUR1" });
  });

  it("returns reviewDecision and maps thread fields", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(page1), asResponse(page2));
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    if (!res.ok) throw new Error("expected ok");
    expect(res.value.reviewDecision).toBe("CHANGES_REQUESTED");
    expect(res.value.threads[1]).toEqual({
      id: "T3", path: "src/a.ts", line: null, originalLine: 9, isOutdated: true,
      author: "carol", body: "Outdated nit.", url: "https://github.com/o/r/pull/12#discussion_rT3",
    });
    expect(res.value.threads[2].author).toBe("ghost");
  });

  it("stops at the page cap if the server keeps saying hasNextPage", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(page1));
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    expect(res.ok).toBe(true);
    expect(stub.fetches.length).toBeLessThanOrEqual(10);
  });

  it("surfaces GraphQL errors[] as Http", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(gqlErrors));
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    expect(res).toMatchObject({ ok: false, error: { kind: "Http" } });
  });

  it("surfaces rate limiting", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(rateLimited));
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    expect(res).toMatchObject({ ok: false, error: { kind: "RateLimited" } });
  });

  it("treats a missing pull request as an error", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, { body: { data: { repository: null } } });
    const res = await fetchReviewThreads(client, "tok", REF, 12);
    expect(res).toMatchObject({ ok: false, error: { kind: "Http", status: 404 } });
  });
});
