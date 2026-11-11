import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import type { GitHubError } from "../src/github/errors";
import { asResponse } from "./fixtureLoader";
import { createStubLeo, START_MS } from "./stubLeo";
import pulls200 from "./fixtures/pulls-200.json";
import pulls304 from "./fixtures/pulls-304.json";
import unauthorized from "./fixtures/401.json";
import rateLimited from "./fixtures/403-ratelimit.json";
import tooMany from "./fixtures/429.json";

const API = "https://api.github.com";
const PULLS = API + "/repos/o/r/pulls?head=o:feat&state=open";
const setup = () => {
  const stub = createStubLeo();
  return { stub, client: createGitHubClient(stub.leo, stub.clock) };
};
const errorOf = <T>(r: { ok: boolean; value?: T; error?: GitHubError }): GitHubError | undefined => (r.ok ? undefined : r.error);

describe("request", () => {
  it("sends bearer auth and GitHub API headers, expanding paths onto api.github.com", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/user", { body: { login: "x" } });
    const res = await client.request("GET", "/user", { auth: "tok" });
    expect(res).toMatchObject({ ok: true, value: { status: 200, json: { login: "x" } } });
    expect(stub.fetches[0].headers).toMatchObject({
      Authorization: "Bearer tok",
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    });
  });

  it("JSON-encodes a body and sets the content type", async () => {
    const { stub, client } = setup();
    stub.route("POST", API + "/repos/o/r/pulls", { status: 201, body: { number: 1 } });
    await client.request("POST", "/repos/o/r/pulls", { auth: "tok", body: { title: "t" } });
    expect(stub.fetches[0].body).toBe('{"title":"t"}');
    expect(stub.fetches[0].headers["Content-Type"]).toBe("application/json");
  });

  it("decodes base64 bodies as UTF-8, including multibyte text", async () => {
    const { stub, client } = setup();
    const text = "héllo ✓ 🚀";
    const b64 = "aMOpbGxvIOKckyDwn5qA"; // base64 of `text`, UTF-8
    stub.route("GET", API + "/log", { body: b64, bodyEncoding: "base64" });
    const res = await client.request("GET", "/log", { auth: "tok" });
    expect(res).toMatchObject({ ok: true, value: { text, json: undefined } });
  });

  it("omits Authorization when auth is null", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/zen", { body: "ok" });
    await client.request("GET", "/zen", { auth: null });
    expect(stub.fetches[0].headers.Authorization).toBeUndefined();
  });

  it("refuses to send a token to any host other than api.github.com", async () => {
    const { stub, client } = setup();
    for (const url of ["https://github.com/x", "https://api.github.com@evil.test/x", "http://api.github.com/x"]) {
      const res = await client.request("GET", url, { auth: "tok" });
      expect(errorOf(res)?.kind).toBe("Transport");
    }
    expect(stub.fetches).toHaveLength(0);
  });

  it.each([
    ["401", unauthorized, { kind: "Unauthorized" }],
    ["403 with remaining 0", rateLimited, { kind: "RateLimited", resetAt: 1767268800 * 1000 }],
    ["429 with retry-after", tooMany, { kind: "RateLimited", resetAt: START_MS + 30_000 }],
  ])("classifies %s", async (_name, fixture, expected) => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", asResponse(fixture));
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual(expected);
  });

  it("treats a plain 403 (no exhausted limit) as Http, not RateLimited", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", { status: 403, headers: { "x-ratelimit-remaining": "12" }, body: { message: "Forbidden" } });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual({
      kind: "Http",
      status: 403,
      body: '{"message":"Forbidden"}',
    });
  });

  it.each([403, 429])("treats a %i secondary limit (no retry-after, remaining > 0, body says rate limit) as RateLimited with a 60 s default", async (status) => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", {
      status,
      headers: { "x-ratelimit-remaining": "12" },
      body: { message: "You have exceeded a secondary Rate Limit. Please wait a few minutes before you try again." },
    });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual({ kind: "RateLimited", resetAt: START_MS + 60_000 });
  });

  it("matches 'rate limit' case-insensitively and also when the headers are absent", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", { status: 403, body: "was RATE LIMITED, slow down" });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual({ kind: "RateLimited", resetAt: START_MS + 60_000 });
  });

  it("honours retry-after over the default on a secondary limit", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", { status: 403, headers: { "retry-after": "90", "x-ratelimit-remaining": "5" }, body: "rate limit" });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual({ kind: "RateLimited", resetAt: START_MS + 90_000 });
  });

  it("does not treat a 422 or a 403 without the phrase as rate limited", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/a", { status: 422, body: "rate limit" });
    stub.route("GET", API + "/b", { status: 403, headers: { "x-ratelimit-remaining": "9" }, body: "Resource not accessible by integration" });
    expect(errorOf(await client.request("GET", "/a", { auth: "tok" }))?.kind).toBe("Http");
    expect(errorOf(await client.request("GET", "/b", { auth: "tok" }))?.kind).toBe("Http");
  });

  it("classifies other statuses as Http with the body text", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", { status: 422, body: { message: "Validation Failed" } });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toMatchObject({ kind: "Http", status: 422 });
  });

  it("classifies a rejected fetch (host rate limit, disallowed host) as Transport", async () => {
    const { stub, client } = setup();
    stub.route("GET", API + "/x", { reject: "rate limited" });
    expect(errorOf(await client.request("GET", "/x", { auth: "tok" }))).toEqual({ kind: "Transport", reason: "rate limited" });
  });
});

describe("getCached", () => {
  it("replays the ETag and returns the cached body as not fresh on 304", async () => {
    const { stub, client } = setup();
    stub.route("GET", PULLS, asResponse(pulls200), asResponse(pulls304));
    const first = await client.getCached(PULLS, { auth: "tok" });
    const second = await client.getCached(PULLS, { auth: "tok" });
    expect(first).toMatchObject({ ok: true, value: { fresh: true, status: 200 } });
    expect(second).toMatchObject({ ok: true, value: { fresh: false, status: 200, json: pulls200.body } });
    expect(stub.fetches[0].headers["If-None-Match"]).toBeUndefined();
    expect(stub.fetches[1].headers["If-None-Match"]).toBe('W/"abc123"');
  });

  it("serves a changed 200 as fresh and updates the stored ETag", async () => {
    const { stub, client } = setup();
    stub.route("GET", PULLS, asResponse(pulls200), { headers: { etag: '"v2"' }, body: [] }, asResponse(pulls304));
    await client.getCached(PULLS, { auth: "tok" });
    await client.getCached(PULLS, { auth: "tok" });
    await client.getCached(PULLS, { auth: "tok" });
    expect(stub.fetches[2].headers["If-None-Match"]).toBe('"v2"');
  });

  it("does not cache error responses", async () => {
    const { stub, client } = setup();
    stub.route("GET", PULLS, asResponse(unauthorized), asResponse(pulls200));
    await client.getCached(PULLS, { auth: "tok" });
    await client.getCached(PULLS, { auth: "tok" });
    expect(stub.fetches[1].headers["If-None-Match"]).toBeUndefined();
  });

  it("clearCache forgets every ETag", async () => {
    const { stub, client } = setup();
    stub.route("GET", PULLS, asResponse(pulls200));
    await client.getCached(PULLS, { auth: "tok" });
    client.clearCache();
    await client.getCached(PULLS, { auth: "tok" });
    expect(stub.fetches[1].headers["If-None-Match"]).toBeUndefined();
  });
});

describe("graphql", () => {
  const GQL = API + "/graphql";

  it("POSTs query and variables and returns data", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, { body: { data: { viewer: { login: "x" } } } });
    const res = await client.graphql<{ viewer: { login: string } }>("query{viewer{login}}", { n: 1 }, { auth: "tok" });
    expect(res).toEqual({ ok: true, value: { viewer: { login: "x" } } });
    expect(JSON.parse(stub.fetches[0].body ?? "")).toEqual({ query: "query{viewer{login}}", variables: { n: 1 } });
  });

  it("turns errors[] into Http", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, { body: { errors: [{ message: "boom" }] } });
    expect(errorOf(await client.graphql("q", {}, { auth: "tok" }))).toMatchObject({ kind: "Http", status: 200 });
  });

  it("turns a RATE_LIMITED error into RateLimited", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, { headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1767268800" }, body: { errors: [{ type: "RATE_LIMITED", message: "x" }] } });
    expect(errorOf(await client.graphql("q", {}, { auth: "tok" }))).toEqual({ kind: "RateLimited", resetAt: 1767268800 * 1000 });
  });

  it("passes REST-level failures through (401)", async () => {
    const { stub, client } = setup();
    stub.route("POST", GQL, asResponse(unauthorized));
    expect(errorOf(await client.graphql("q", {}, { auth: "tok" }))).toEqual({ kind: "Unauthorized" });
  });
});
