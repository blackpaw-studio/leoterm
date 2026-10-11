import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { issueGrant, verifyGrant } from "../src/grant";
import { JWT_MAX_AGE_SECONDS } from "../src/jwt";
import { type Env, createRelay } from "../src/relay";
import {
  CIPHERTEXT,
  COLLAPSE_ID,
  SECRET,
  TOKEN,
  type TestKey,
  apnsError,
  b64urlToBytes,
  b64urlToJson,
  fakeApns,
  fakeLimiter,
  makeEnv,
  makeKey,
  post,
} from "./helpers";

let key: TestKey;
beforeAll(async () => {
  key = await makeKey();
});
afterEach(() => vi.restoreAllMocks());

const NOW_MS = 1_700_000_000_000;

const setup = (apns = fakeApns(), envOverrides: Partial<Env> = {}) => {
  let ms = NOW_MS;
  const env = makeEnv(key.pem, envOverrides);
  // a fresh relay per test: each owns its own JWT cache
  const relay = createRelay({ fetch: apns.fetch, now: () => ms });
  return {
    apns,
    env,
    advance: (seconds: number) => void (ms += seconds * 1000),
    call: (req: Request) => relay(req, env),
  };
};

const grantFor = (e: "sandbox" | "production" = "sandbox", t = TOKEN) => issueGrant(SECRET, { t, e });
const pushBody = async (over: Record<string, unknown> = {}) => ({
  grant: await grantFor(),
  ciphertext: CIPHERTEXT,
  collapse_id: COLLAPSE_ID,
  ...over,
});

describe("routing", () => {
  it.each([
    ["GET", "/push"],
    ["GET", "/register"],
    ["PUT", "/push"],
    ["POST", "/"],
    ["POST", "/pushes"],
    ["POST", "/push/extra"],
    ["POST", "/Register"],
  ])("answers 404 for %s %s without echoing the path", async (method, path) => {
    const { call, apns } = setup();
    const res = await call(new Request(`https://relay.test${path}`, { method, body: method === "GET" ? undefined : "{}" }));
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain(path.slice(1) || "zzz-never");
    expect(apns.calls).toEqual([]);
  });
});

describe("POST /register", () => {
  it("returns a grant that verifies for the token and env", async () => {
    const { call } = setup();
    const res = await call(post("/register", { apns_token: TOKEN, env: "production" }));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const { grant } = (await res.json()) as { grant: string };
    expect(await verifyGrant(SECRET, grant)).toEqual({ t: TOKEN, e: "production" });
  });

  it("normalizes the token to lowercase hex", async () => {
    const { call } = setup();
    const res = await call(post("/register", { apns_token: TOKEN.toUpperCase(), env: "sandbox" }));
    const { grant } = (await res.json()) as { grant: string };
    expect(await verifyGrant(SECRET, grant)).toEqual({ t: TOKEN, e: "sandbox" });
  });

  it("rate-limits per client IP and answers 429 when the limiter refuses", async () => {
    const limiter = fakeLimiter();
    const { call } = setup(fakeApns(), { REGISTER_LIMITER: limiter });
    await call(post("/register", { apns_token: TOKEN, env: "sandbox" }, { "cf-connecting-ip": "203.0.113.7" }));
    expect(limiter.keys).toEqual(["203.0.113.7"]);

    const refused = setup(fakeApns(), { REGISTER_LIMITER: fakeLimiter(false) });
    const res = await refused.call(post("/register", { apns_token: TOKEN, env: "sandbox" }));
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
  });

  it.each([
    ["not JSON", "{nope"],
    ["JSON null", "null"],
    ["JSON array", "[]"],
    ["missing token", { env: "sandbox" }],
    ["missing env", { apns_token: TOKEN }],
    ["token not hex", { apns_token: "zz".repeat(32), env: "sandbox" }],
    ["token too short", { apns_token: "ab", env: "sandbox" }],
    ["token odd length", { apns_token: "a".repeat(65), env: "sandbox" }],
    ["token not a string", { apns_token: 12, env: "sandbox" }],
    ["env unknown", { apns_token: TOKEN, env: "staging" }],
    ["env boolean", { apns_token: TOKEN, env: true }],
    ["unknown field", { apns_token: TOKEN, env: "sandbox", sandbox: true }],
  ])("400 for %s, never echoing the input", async (_name, body) => {
    const { call } = setup();
    const res = await call(post("/register", body));
    expect(res.status).toBe(400);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ error: "bad_request" });
  });

  it("413 for an oversized body", async () => {
    const { call } = setup();
    const res = await call(post("/register", JSON.stringify({ apns_token: TOKEN, env: "sandbox", pad: "x".repeat(10_000) })));
    expect(res.status).toBe(413);
  });
});

describe("POST /push — grant verification", () => {
  const rejectsWith401 = async (grant: unknown, envOverrides: Partial<Env> = {}) => {
    const limiter = fakeLimiter();
    const { call, apns } = setup(fakeApns(), { PUSH_LIMITER: limiter, ...envOverrides });
    const res = await call(post("/push", await pushBody({ grant })));
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
    expect(apns.calls).toEqual([]);
    expect(limiter.keys).toEqual([]); // forged grants must not mint rate-limit buckets
  };

  it("rejects a grant minted under a different secret", async () => {
    await rejectsWith401(await issueGrant("someone-elses-secret", { t: TOKEN, e: "sandbox" }));
  });

  it("rejects every grant once GRANT_SECRET is rotated", async () => {
    await rejectsWith401(await grantFor(), { GRANT_SECRET: "rotated" });
  });

  it("rejects a tampered payload", async () => {
    const [, mac] = (await grantFor("sandbox")).split(".");
    const swapped = btoa(JSON.stringify({ t: "cd".repeat(32), e: "sandbox" })).replace(/=+$/, "");
    await rejectsWith401(`${swapped}.${mac}`);
  });

  it("rejects the payload re-pointed at production with the sandbox mac", async () => {
    const [, mac] = (await grantFor("sandbox")).split(".");
    const prod = btoa(JSON.stringify({ t: TOKEN, e: "production" })).replace(/=+$/, "");
    await rejectsWith401(`${prod}.${mac}`);
  });

  it("rejects a tampered mac", async () => {
    const [payload, mac] = (await grantFor()).split(".");
    await rejectsWith401(`${payload}.${(mac[0] === "A" ? "B" : "A") + mac.slice(1)}`);
  });

  it.each(["", "garbage", "a.b.c", "abc.", ".abc", "###.###"])("rejects malformed grant %j", async (g) => {
    await rejectsWith401(g);
  });
});

describe("POST /push — validation", () => {
  it.each([
    ["not JSON", "{"],
    ["JSON array", "[]"],
  ])("400 for %s", async (_n, body) => {
    const { call } = setup();
    expect((await call(post("/push", body))).status).toBe(400);
  });

  it.each([
    ["missing grant", { grant: undefined }],
    ["grant not a string", { grant: 7 }],
    ["missing ciphertext", { ciphertext: undefined }],
    ["ciphertext not base64", { ciphertext: "not base64!!" }],
    ["ciphertext empty", { ciphertext: "" }],
    ["missing collapse_id", { collapse_id: undefined }],
    ["collapse_id too long for APNs", { collapse_id: "a".repeat(65) }],
    ["collapse_id with illegal chars", { collapse_id: "a b\r\nx" }],
    ["unknown field", { apns_token: TOKEN }],
  ])("400 for %s, no APNs call", async (_n, over) => {
    const { call, apns } = setup();
    const res = await call(post("/push", await pushBody(over)));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "bad_request" });
    expect(apns.calls).toEqual([]);
  });

  it("accepts a ciphertext of exactly 2048 characters", async () => {
    const { call } = setup();
    const res = await call(post("/push", await pushBody({ ciphertext: "A".repeat(2048) })));
    expect(res.status).toBe(202);
  });

  it("413 for a ciphertext over 2 KiB, no APNs call", async () => {
    const { call, apns } = setup();
    const res = await call(post("/push", await pushBody({ ciphertext: "A".repeat(2049) })));
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "payload_too_large" });
    expect(apns.calls).toEqual([]);
  });

  it("413 for an enormous body without parsing it", async () => {
    const { call, apns } = setup();
    const res = await call(post("/push", "x".repeat(100_000)));
    expect(res.status).toBe(413);
    expect(apns.calls).toEqual([]);
  });
});

describe("request body cap", () => {
  const withPath = (req: Request, path: string): Request =>
    new Request(`https://relay.test${path}`, { method: "POST", headers: req.headers, body: req.body, duplex: "half" } as RequestInit);

  const streamed = (chunks: number, chunkBytes: number, headers: Record<string, string> = {}) => {
    const state = { pulls: 0, cancelled: false };
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        state.pulls += 1;
        if (state.pulls > chunks) return controller.close();
        controller.enqueue(new Uint8Array(chunkBytes).fill(0x20));
      },
      cancel() {
        state.cancelled = true;
      },
    });
    const req = new Request("https://relay.test/push", {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body,
      duplex: "half",
    } as RequestInit);
    return { req, state };
  };

  it.each(["/push", "/register"])("%s: rejects a declared Content-Length over the cap without reading the body", async (path) => {
    const { call } = setup();
    const { req, state } = streamed(1, 16, { "content-length": "1000000" });
    const res = await call(withPath(req, path));
    expect(res.status).toBe(413);
    expect(state.cancelled).toBe(true);
    expect(state.pulls).toBeLessThanOrEqual(1); // the stream's own priming pull; the relay never reads
  });

  it.each(["/push", "/register"])("%s: cancels a chunked stream as soon as the cap is crossed", async (path) => {
    const { call } = setup();
    const { req, state } = streamed(10_000, 1024);
    const res = await call(withPath(req, path));
    expect(res.status).toBe(413);
    expect(state.cancelled).toBe(true);
    expect(state.pulls).toBeLessThan(20); // 4 KiB cap, 1 KiB chunks (plus read-ahead), never the 10 MB offered
  });

  it("counts bytes, not characters: 4 KiB of multibyte text is over the cap", async () => {
    const { call } = setup();
    const res = await call(post("/push", JSON.stringify({ pad: "é".repeat(2500) })));
    expect(res.status).toBe(413);
  });
});

describe("POST /push — rate limit", () => {
  it("keys the limiter by the verified {token, env}, not by the raw grant string or the token itself", async () => {
    const limiter = fakeLimiter();
    const ok = setup(fakeApns(), { PUSH_LIMITER: limiter });
    const body = await pushBody();
    await ok.call(post("/push", body));
    await ok.call(post("/push", await pushBody({ grant: await grantFor("sandbox") })));
    await ok.call(post("/push", await pushBody({ grant: await grantFor("production") })));
    await ok.call(post("/push", await pushBody({ grant: await grantFor("sandbox", "cd".repeat(32)) })));

    const [a, b, prod, other] = limiter.keys;
    expect(a).toBe(b);
    expect(new Set([a, prod, other]).size).toBe(3);
    for (const k of limiter.keys) {
      expect(k).not.toContain(TOKEN);
      expect(k).not.toBe(body.grant);
    }
  });

  it("gives every noncanonical spelling of one grant the same bucket or a 401 (no extra buckets)", async () => {
    const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const limiter = fakeLimiter();
    const { call, apns } = setup(fakeApns(), { PUSH_LIMITER: limiter });
    const [payload, mac] = (await grantFor()).split(".");
    const last = ALPHABET.indexOf(mac.at(-1)!);
    for (const spare of [0, 1, 2, 3]) {
      const grant = `${payload}.${mac.slice(0, -1)}${ALPHABET[last + spare]}`;
      await call(post("/push", await pushBody({ grant })));
    }
    expect(new Set(limiter.keys).size).toBe(1);
    expect(apns.calls).toHaveLength(1);
  });

  it("answers 429 when refused", async () => {
    const body = await pushBody();

    const refused = setup(fakeApns(), { PUSH_LIMITER: fakeLimiter(false) });
    const res = await refused.call(post("/push", body));
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
    expect(refused.apns.calls).toEqual([]);
  });
});

describe("POST /push — APNs request", () => {
  it("202s and sends the exact contract request to the host for the grant's env", async () => {
    const { call, apns } = setup();
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(202);

    expect(apns.calls).toHaveLength(1);
    const [c] = apns.calls;
    expect(c.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(c.method).toBe("POST");
    expect(c.headers.get("apns-push-type")).toBe("alert");
    expect(c.headers.get("apns-priority")).toBe("10");
    expect(c.headers.get("apns-collapse-id")).toBe(COLLAPSE_ID);
    expect(c.headers.get("apns-topic")).toBe("studio.blackpaw.leo.ios");
    expect(c.headers.get("content-type")).toBe("application/json");
    expect(c.body).toBe(
      JSON.stringify({
        aps: {
          alert: { title: "Leo", body: "An agent needs you" },
          "mutable-content": 1,
          sound: "default",
          "thread-id": COLLAPSE_ID,
        },
        c: CIPHERTEXT,
      }),
    );
  });

  it("uses the production host for a production grant", async () => {
    const { call, apns } = setup();
    await call(post("/push", await pushBody({ grant: await grantFor("production") })));
    expect(apns.calls[0].url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
  });

  it("authorizes with a verifiable ES256 provider token", async () => {
    const { call, apns } = setup();
    await call(post("/push", await pushBody()));
    const auth = apns.calls[0].headers.get("authorization")!;
    expect(auth.startsWith("bearer ")).toBe(true);
    const [h, claims, sig] = auth.slice(7).split(".");
    expect(b64urlToJson(h)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(b64urlToJson(claims)).toEqual({ iss: "TEAM123456", iat: NOW_MS / 1000 });
    expect(
      await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        key.publicKey,
        b64urlToBytes(sig),
        new TextEncoder().encode(`${h}.${claims}`),
      ),
    ).toBe(true);
  });

  it("reuses the provider token across pushes and re-signs after it ages out", async () => {
    const { call, apns, advance } = setup();
    const bearers = async () => {
      await call(post("/push", await pushBody()));
      return apns.calls.at(-1)!.headers.get("authorization");
    };
    const first = await bearers();
    advance(JWT_MAX_AGE_SECONDS - 1);
    expect(await bearers()).toBe(first);
    advance(1);
    const refreshed = await bearers();
    expect(refreshed).not.toBe(first);
  });
});

describe("POST /push — APNs failures", () => {
  it("maps 400 BadDeviceToken (incl. env mismatch) to 400, so a daemon keeps the registration", async () => {
    const { call } = setup(fakeApns(() => apnsError(400, "BadDeviceToken")));
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "bad_request" });
  });

  it.each([
    ["410 Unregistered", () => apnsError(410, "Unregistered")],
    ["410 with empty body", () => new Response(null, { status: 410 })],
    ["400 Unregistered", () => apnsError(400, "Unregistered")],
  ])("maps %s to 410", async (_n, respond) => {
    const { call } = setup(fakeApns(respond));
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: "gone" });
  });

  it.each([
    ["400 DeviceTokenNotForTopic", () => apnsError(400, "DeviceTokenNotForTopic")],
    ["429 TooManyRequests", () => apnsError(429, "TooManyRequests")],
    ["500", () => apnsError(500, "InternalServerError")],
    ["a non-JSON body", () => new Response("<html>nope</html>", { status: 503 })],
  ])("maps %s to 502 without echoing Apple's reason", async (_n, respond) => {
    const { call } = setup(fakeApns(respond));
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(502);
    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ error: "upstream_error" });
  });

  it("maps a network failure to 502 without leaking the error", async () => {
    const { call } = setup(
      fakeApns(() => {
        throw new TypeError(`connect failed https://api.push.apple.com/3/device/${TOKEN}`);
      }),
    );
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(502);
    expect(await res.text()).not.toContain(TOKEN);
  });

  it("drops the cached provider token when Apple rejects it, so the next push re-signs", async () => {
    const { call, apns } = setup(fakeApns((n) => (n === 0 ? apnsError(403, "ExpiredProviderToken") : new Response(null, { status: 200 }))));
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(502);

    // same clock => a re-sign yields the same iat but signatures differ (ECDSA is randomized)
    expect((await call(post("/push", await pushBody()))).status).toBe(202);
    expect(apns.calls[1].headers.get("authorization")).not.toBe(apns.calls[0].headers.get("authorization"));
  });

  it("500s with a bare error when a secret is not configured", async () => {
    const { call } = setup(fakeApns(), { APNS_P8: "" });
    const res = await call(post("/push", await pushBody()));
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "internal" });
  });
});

describe("secrecy", () => {
  it("never logs tokens, grants or ciphertext on any path", async () => {
    const logs = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
    const grant = await grantFor();
    const secrets = [TOKEN, grant, CIPHERTEXT, key.pem];
    const failing = setup(
      fakeApns(() => {
        throw new Error(`boom ${TOKEN} ${grant}`);
      }),
    );
    const gone = setup(fakeApns(() => apnsError(410, "Unregistered")));

    await failing.call(post("/push", await pushBody({ grant })));
    await gone.call(post("/push", await pushBody({ grant })));
    await failing.call(post("/push", await pushBody({ grant: "bad" })));
    await failing.call(post("/register", { apns_token: TOKEN, env: "sandbox" }));
    await setup(fakeApns(), { APNS_P8: "" }).call(post("/push", await pushBody({ grant })));
    const brokenLimiter: RateLimit = {
      limit: async () => {
        throw new Error(`limiter exploded on ${grant}`);
      },
    };
    const res = await setup(fakeApns(), { PUSH_LIMITER: brokenLimiter }).call(post("/push", await pushBody({ grant })));
    expect(res.status).toBe(500);
    expect(await res.text()).not.toContain(grant);

    const logged = JSON.stringify(logs.flatMap((l) => l.mock.calls));
    for (const s of secrets) expect(logged).not.toContain(s);
  });
});
