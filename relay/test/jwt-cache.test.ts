import { beforeAll, describe, expect, it, vi } from "vitest";
import { JWT_MAX_AGE_SECONDS, createJwtProvider } from "../src/jwt";
import { type TestKey, b64urlToBytes, b64urlToJson, makeKey } from "./helpers";

let key: TestKey;
beforeAll(async () => {
  key = await makeKey();
});

const creds = () => ({ p8: key.pem, keyId: "ABC123DEFG", teamId: "TEAM123456" });

const clock = (startSeconds: number) => {
  let ms = startSeconds * 1000;
  return { now: () => ms, advance: (seconds: number) => void (ms += seconds * 1000) };
};

describe("createJwtProvider", () => {
  it("re-signs no sooner than 20 and no later than 50 minutes", () => {
    expect(JWT_MAX_AGE_SECONDS).toBeGreaterThanOrEqual(20 * 60);
    expect(JWT_MAX_AGE_SECONDS).toBeLessThanOrEqual(50 * 60);
  });

  it("signs an ES256 token with kid, iss and the injected iat, verifiable with the public key", async () => {
    const c = clock(1_700_000_000);
    const jwt = await createJwtProvider({ now: c.now }).get(creds());
    const [h, claims, sig] = jwt.split(".");

    expect(b64urlToJson(h)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(b64urlToJson(claims)).toEqual({ iss: "TEAM123456", iat: 1_700_000_000 });
    expect(b64urlToBytes(sig).length).toBe(64);
    expect(
      await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        key.publicKey,
        b64urlToBytes(sig),
        new TextEncoder().encode(`${h}.${claims}`),
      ),
    ).toBe(true);
  });

  it("reuses the token until it ages out, then signs a fresh one", async () => {
    const c = clock(1_700_000_000);
    const sign = vi.fn(async ({ now }: { now: number }) => `jwt-${now}`);
    const provider = createJwtProvider({ now: c.now, sign });

    const first = await provider.get(creds());
    c.advance(JWT_MAX_AGE_SECONDS - 1);
    expect(await provider.get(creds())).toBe(first);
    expect(sign).toHaveBeenCalledTimes(1);

    c.advance(1);
    const second = await provider.get(creds());
    expect(second).not.toBe(first);
    expect(sign).toHaveBeenCalledTimes(2);
  });

  it("signs once for concurrent first callers", async () => {
    const sign = vi.fn(async () => "jwt");
    const provider = createJwtProvider({ now: () => 0, sign });
    await Promise.all([provider.get(creds()), provider.get(creds()), provider.get(creds())]);
    expect(sign).toHaveBeenCalledTimes(1);
  });

  it("signs again after invalidate()", async () => {
    const sign = vi.fn(async () => "jwt");
    const provider = createJwtProvider({ now: () => 0, sign });
    await provider.get(creds());
    provider.invalidate();
    await provider.get(creds());
    expect(sign).toHaveBeenCalledTimes(2);
  });

  it("signs again when the credentials change", async () => {
    const sign = vi.fn(async () => "jwt");
    const provider = createJwtProvider({ now: () => 0, sign });
    await provider.get(creds());
    await provider.get({ ...creds(), keyId: "OTHERKEYID" });
    expect(sign).toHaveBeenCalledTimes(2);
  });

  it("does not cache a failed signing", async () => {
    const sign = vi.fn().mockRejectedValueOnce(new Error("boom")).mockResolvedValue("jwt");
    const provider = createJwtProvider({ now: () => 0, sign });
    await expect(provider.get(creds())).rejects.toThrow("boom");
    expect(await provider.get(creds())).toBe("jwt");
  });
});
