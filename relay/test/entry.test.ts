import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { issueGrant } from "../src/grant";
import { CIPHERTEXT, COLLAPSE_ID, TOKEN } from "./helpers";

afterEach(() => vi.unstubAllGlobals());

const call = (path: string, body: unknown, ip = "198.51.100.1") =>
  exports.default.fetch(
    new Request(`https://relay.test${path}`, {
      method: "POST",
      headers: { "cf-connecting-ip": ip, "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  );

describe("worker entry (real Miniflare bindings)", () => {
  it("registers over the real REGISTER_LIMITER and 429s once 10/min is spent", async () => {
    const ip = "198.51.100.77";
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) statuses.push((await call("/register", { apns_token: TOKEN, env: "sandbox" }, ip)).status);
    expect(statuses.slice(0, 10)).toEqual(new Array(10).fill(200));
    expect(statuses[10]).toBe(429);
    // another client is unaffected
    expect((await call("/register", { apns_token: TOKEN, env: "sandbox" }, "198.51.100.78")).status).toBe(200);
  });

  it("pushes end to end and reuses one module-scope provider token across requests", async () => {
    const apnsFetch = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", apnsFetch);
    const grant = await issueGrant(env.GRANT_SECRET, { t: TOKEN, e: "production" });

    const a = await call("/push", { grant, ciphertext: CIPHERTEXT, collapse_id: COLLAPSE_ID }, "198.51.100.90");
    const b = await call("/push", { grant, ciphertext: CIPHERTEXT, collapse_id: COLLAPSE_ID }, "198.51.100.91");

    expect([a.status, b.status]).toEqual([202, 202]);
    const bearer = (n: number) => new Headers((apnsFetch.mock.calls[n] as unknown as [string, RequestInit])[1].headers).get("authorization");
    expect(apnsFetch).toHaveBeenCalledTimes(2);
    expect(bearer(0)).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(bearer(1)).toBe(bearer(0));
  });
});
