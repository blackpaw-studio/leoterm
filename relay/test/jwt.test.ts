import { describe, expect, it } from "vitest";
import { derToRawEs256, signApnsJwt } from "../src/jwt";

const b64urlToBytes = (s: string): Uint8Array =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const b64urlToJson = (s: string) => JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));

const toPem = (pkcs8: ArrayBuffer): string => {
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  return `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
};

describe("derToRawEs256", () => {
  it("left-pads short r/s and strips DER sign padding to 64 bytes", () => {
    // r = 0x00 0x80.. (33 bytes, sign pad), s = 1 byte
    const r = new Uint8Array([0x00, 0x80, ...new Array(31).fill(0x11)]);
    const s = new Uint8Array([0x05]);
    const der = new Uint8Array([0x30, 2 + r.length + 2 + s.length, 0x02, r.length, ...r, 0x02, s.length, ...s]);
    const raw = derToRawEs256(der);
    expect(raw.length).toBe(64);
    expect(raw[0]).toBe(0x80);
    expect(raw.slice(32, 63).every((b) => b === 0)).toBe(true);
    expect(raw[63]).toBe(0x05);
  });

  it("handles long-form DER sequence length (0x81)", () => {
    const r = new Uint8Array([0x00, ...new Array(32).fill(0xff)]);
    const s = new Uint8Array([0x00, ...new Array(32).fill(0xee)]);
    const body = [0x02, r.length, ...r, 0x02, s.length, ...s];
    const der = new Uint8Array([0x30, 0x81, body.length, ...body]);
    const raw = derToRawEs256(der);
    expect(raw.slice(0, 32).every((b) => b === 0xff)).toBe(true);
    expect(raw.slice(32).every((b) => b === 0xee)).toBe(true);
  });

  it("rejects non-DER input", () => {
    expect(() => derToRawEs256(new Uint8Array([1, 2, 3]))).toThrow();
  });
});

describe("signApnsJwt", () => {
  it("emits ES256 header with kid, iss/iat claims, and a verifiable raw signature", async () => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const pem = toPem((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);

    const jwt = await signApnsJwt({ p8: pem, keyId: "ABC123DEFG", teamId: "TEAM123456", now: 1_700_000_000 });
    const [h, c, sig] = jwt.split(".");

    expect(b64urlToJson(h)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(b64urlToJson(c)).toEqual({ iss: "TEAM123456", iat: 1_700_000_000 });
    expect(b64urlToBytes(sig).length).toBe(64);

    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      b64urlToBytes(sig),
      new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it("accepts a .p8 whose newlines were escaped as \\n (env var style)", async () => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const pem = toPem((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer).replace(/\n/g, "\\n");
    const jwt = await signApnsJwt({ p8: pem, keyId: "K", teamId: "T", now: 1 });
    expect(jwt.split(".")).toHaveLength(3);
  });
});
