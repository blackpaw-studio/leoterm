import { describe, expect, it } from "vitest";
import type { SlotID, SlotRoot } from "../../sdk/leo";
import { createSession, defaultSignInViews } from "../src/auth/session";
import { OAUTH_CLIENT_ID } from "../src/config";
import { createGitHubClient } from "../src/github/client";
import { createStubLeo } from "./stubLeo";
import unauthorized from "./fixtures/401.json";
import { asResponse } from "./fixtureLoader";

const CLIENT_ID = "test-client-id";
const DEVICE_CODE = "https://github.com/login/device/code";
const ACCESS_TOKEN = "https://github.com/login/oauth/access_token";
const API = "https://api.github.com";
const view: SlotID = { kind: "view", viewID: "github", agent: { machine: "m", name: "alpha" } };
const section: SlotID = { kind: "section", id: "assigned-issues" };

const deviceCode = (extra: Record<string, unknown> = {}) => ({
  body: { device_code: "dc-secret", user_code: "ABCD-1234", verification_uri: "https://github.com/login/device", expires_in: 900, interval: 5, ...extra },
});
const pending = { body: { error: "authorization_pending" } };

const setup = (clientId: string | undefined = CLIENT_ID) => {
  const stub = createStubLeo();
  const client = createGitHubClient(stub.leo, stub.clock);
  const session = createSession({ leo: stub.leo, clock: stub.clock, client, clientId });
  return { stub, client, session };
};
const titleOf = (root: SlotRoot | undefined): string | undefined => {
  const node = Array.isArray(root) ? root[0] : root;
  return node && "title" in node ? node.title : undefined;
};
const json = (value: unknown): string => JSON.stringify(value);

describe("config", () => {
  it("ships without an OAuth client ID until the app is registered", () => {
    expect(OAUTH_CLIENT_ID).toBe("");
  });
});

describe("sign-in without a client ID", () => {
  it("explains it isn't configured and makes no request", async () => {
    const { stub, session } = setup("");
    await session.startSignIn(view);
    expect(titleOf(stub.lastRender(view))).toBe("GitHub sign-in isn't configured in this build");
    expect(stub.fetches).toEqual([]);
  });
});

describe("device flow", () => {
  it("requests a code with a form body and shows it with open and copy actions", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    await session.startSignIn(view);
    expect(stub.fetches[0]).toMatchObject({ method: "POST", url: DEVICE_CODE });
    expect(stub.fetches[0].headers).toMatchObject({ Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" });
    expect(stub.fetches[0].body).toBe("client_id=test-client-id&scope=repo%20read%3Aorg");
    const rendered = json(stub.lastRender(view));
    expect(rendered).toContain("ABCD-1234");
    expect(rendered).toContain('"type":"openURL","url":"https://github.com/login/device"');
    expect(rendered).toContain('"type":"copy","text":"ABCD-1234"');
    expect(rendered).not.toContain("dc-secret");
  });

  it("polls at the interval, backs off 5 s on slow_down, and stores the token on success", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, pending, { body: { error: "slow_down" } }, { body: { access_token: "gho_tok", token_type: "bearer" } });
    const events: string[] = [];
    session.subscribe((e) => events.push(e));
    await session.startSignIn(view);

    await stub.tick(4);
    expect(stub.fetches).toHaveLength(1); // no poll before the 5 s interval
    await stub.tick(1);
    expect(stub.fetches).toHaveLength(2); // pending
    expect(stub.fetches[1].body).toContain("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code");
    expect(stub.fetches[1].body).toContain("device_code=dc-secret");
    await stub.tick(5);
    expect(stub.fetches).toHaveLength(3); // slow_down
    await stub.tick(9);
    expect(stub.fetches).toHaveLength(3); // interval is now 10 s
    await stub.tick(1);
    expect(stub.fetches).toHaveLength(4);
    expect(stub.secretStore.get("token")).toBe("gho_tok");
    expect(session.token()).toBe("gho_tok");
    expect(events).toEqual(["signedIn"]);

    await stub.tick(60);
    expect(stub.fetches).toHaveLength(4); // polling stopped
  });

  it("never renders or logs the token", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, { body: { access_token: "gho_tok" } });
    await session.startSignIn(view);
    await stub.tick(5);
    expect(json(stub.renders)).not.toContain("gho_tok");
    expect(json(stub.logs)).not.toContain("gho_tok");
  });

  it.each([
    ["expired_token", "Code expired"],
    ["access_denied", "Denied"],
  ])("stops polling on %s and offers a retry", async (error, title) => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, { body: { error } });
    await session.startSignIn(view);
    await stub.tick(5);
    expect(titleOf(stub.lastRender(view))).toBe(title);
    expect(json(stub.lastRender(view))).toContain('"id":"sign-in"');
    await stub.tick(120);
    expect(stub.fetches).toHaveLength(2);
    expect(session.token()).toBeNull();
  });

  it("expires locally when the code's lifetime passes without an answer", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode({ expires_in: 10 }));
    stub.route("POST", ACCESS_TOKEN, pending);
    await session.startSignIn(view);
    await stub.tick(10);
    expect(titleOf(stub.lastRender(view))).toBe("Code expired");
    expect(stub.fetches).toHaveLength(2); // code request and one poll
  });

  it("keeps polling through a transient network failure", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, { reject: "offline" }, { body: { access_token: "gho_tok" } });
    await session.startSignIn(view);
    await stub.tick(10);
    expect(session.token()).toBe("gho_tok");
  });

  it("fails on an unexpected error code", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, { body: { error: "incorrect_client_credentials" } });
    await session.startSignIn(view);
    await stub.tick(5);
    expect(titleOf(stub.lastRender(view))).toBe("Sign-in failed");
    expect(json(stub.lastRender(view))).toContain("incorrect_client_credentials");
  });

  it("shows a failure when the device code request is rejected", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, { reject: "offline" });
    await session.startSignIn(view);
    expect(titleOf(stub.lastRender(view))).toBe("Sign-in failed");
  });

  it("restarting abandons the previous flow", async () => {
    const { stub, session } = setup();
    stub.route("POST", DEVICE_CODE, deviceCode(), deviceCode({ device_code: "dc-two", user_code: "WXYZ-9999" }));
    stub.route("POST", ACCESS_TOKEN, pending);
    await session.startSignIn(view);
    await session.startSignIn(view);
    await stub.tick(5);
    const polls = stub.fetches.filter((f) => f.url === ACCESS_TOKEN);
    expect(polls).toHaveLength(1);
    expect(polls[0].body).toContain("dc-two");
  });
});

describe("session", () => {
  it("loads the stored token", async () => {
    const { stub, session } = setup();
    stub.secretStore.set("token", "gho_saved");
    await session.load();
    expect(session.token()).toBe("gho_saved");
  });

  it("clears the token and caches on a 401 and flips every known slot to sign-in", async () => {
    const { stub, client, session } = setup();
    stub.secretStore.set("token", "gho_saved");
    await session.load();
    session.track(view);
    session.track(section);
    const events: string[] = [];
    session.subscribe((e) => events.push(e));

    const pulls = API + "/repos/o/r/pulls";
    stub.route("GET", pulls, { body: [1], headers: { etag: '"v1"' } }, { status: 304 });
    stub.route("GET", API + "/user", asResponse(unauthorized));
    await client.getCached(pulls, { auth: session.token() });
    const res = await client.request("GET", "/user", { auth: session.token() });
    expect(res.ok).toBe(false);
    if (res.ok) return;

    expect(await session.handleError(res.error, "gho_saved")).toBe(true);
    expect(session.token()).toBeNull();
    expect(stub.secretStore.has("token")).toBe(false);
    expect(titleOf(stub.lastRender(view))).toBe("Sign in to GitHub");
    expect(titleOf(stub.lastRender(section))).toBe("Sign in to GitHub");
    expect(events).toEqual(["signedOut"]);

    // the ETag cache was cleared: the next GET is unconditional
    await client.getCached(pulls, { auth: null });
    expect(stub.fetches[stub.fetches.length - 1]?.headers["If-None-Match"]).toBeUndefined();
  });

  it("handles a burst of simultaneous 401s once", async () => {
    const { stub, session } = setup();
    stub.secretStore.set("token", "gho_saved");
    await session.load();
    session.track(view);
    const events: string[] = [];
    session.subscribe((e) => events.push(e));
    await Promise.all([1, 2, 3].map(() => session.handleError({ kind: "Unauthorized" }, "gho_saved")));
    expect(events).toEqual(["signedOut"]);
    expect(stub.rendersFor(view)).toHaveLength(1);
  });

  it("ignores a late 401 from a request made with an earlier token", async () => {
    const { stub, session } = setup();
    stub.secretStore.set("token", "gho_new");
    await session.load();
    expect(await session.handleError({ kind: "Unauthorized" }, "gho_old")).toBe(true);
    expect(session.token()).toBe("gho_new");
    expect(stub.secretStore.get("token")).toBe("gho_new");
  });

  it("leaves the token alone for other errors", async () => {
    const { stub, session } = setup();
    stub.secretStore.set("token", "gho_saved");
    await session.load();
    expect(await session.handleError({ kind: "Http", status: 500, body: "" }, "gho_saved")).toBe(false);
    expect(await session.handleError({ kind: "RateLimited", resetAt: 1 }, "gho_saved")).toBe(false);
    expect(session.token()).toBe("gho_saved");
  });

  it("signs out: deletes the token, clears caches, cancels a running flow and redraws slots", async () => {
    const { stub, session } = setup();
    stub.secretStore.set("token", "gho_saved");
    await session.load();
    session.track(section);
    stub.route("POST", DEVICE_CODE, deviceCode());
    stub.route("POST", ACCESS_TOKEN, pending);
    await session.startSignIn(view);
    await session.signOut();
    expect(session.token()).toBeNull();
    expect(stub.secretStore.size).toBe(0);
    expect(titleOf(stub.lastRender(section))).toBe("Sign in to GitHub");
    expect(titleOf(stub.lastRender(view))).toBe("Sign in to GitHub");
    await stub.tick(60);
    expect(stub.fetches.filter((f) => f.url === ACCESS_TOKEN)).toHaveLength(0);
  });
});

describe("signed-out copy", () => {
  const msg = (slot: Parameters<typeof defaultSignInViews.signedOut>[0]) => JSON.stringify(defaultSignInViews.signedOut(slot));
  it("mentions issues in the issues section, and PRs and checks on agent slots", () => {
    expect(msg({ kind: "section", id: "issues" } as never)).toMatch(/issues/);
    expect(msg({ kind: "section", id: "issues" } as never)).not.toMatch(/pull requests|checks/);
    expect(msg({ kind: "view", agent: { id: "a" } } as never)).toMatch(/pull requests and checks/);
  });
});
