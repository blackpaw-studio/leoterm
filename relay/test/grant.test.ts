import { describe, expect, it } from "vitest";
import { issueGrant, verifyGrant } from "../src/grant";
import { SECRET, TOKEN, b64urlToJson } from "./helpers";

const claims = { t: TOKEN, e: "sandbox" as const };

describe("grant", () => {
  it("is b64url(JSON{t,e}) + '.' + b64url(mac)", async () => {
    const grant = await issueGrant(SECRET, claims);
    const [payload, mac, ...rest] = grant.split(".");
    expect(rest).toEqual([]);
    expect(b64urlToJson(payload)).toEqual(claims);
    expect(mac).toMatch(/^[A-Za-z0-9_-]{43}$/); // 32 bytes, unpadded
  });

  it("round-trips under the same secret", async () => {
    expect(await verifyGrant(SECRET, await issueGrant(SECRET, claims))).toEqual(claims);
  });

  it("rejects a grant signed with a different secret", async () => {
    expect(await verifyGrant(SECRET, await issueGrant("other-secret", claims))).toBeNull();
  });

  it("rejects a tampered payload", async () => {
    const [, mac] = (await issueGrant(SECRET, claims)).split(".");
    const forged = btoa(JSON.stringify({ t: "cd".repeat(32), e: "sandbox" })).replace(/=+$/, "");
    expect(await verifyGrant(SECRET, `${forged}.${mac}`)).toBeNull();
  });

  it("rejects a tampered mac", async () => {
    const [payload, mac] = (await issueGrant(SECRET, claims)).split(".");
    const flipped = (mac[0] === "A" ? "B" : "A") + mac.slice(1);
    expect(await verifyGrant(SECRET, `${payload}.${flipped}`)).toBeNull();
  });

  it("rejects noncanonical base64url encodings of an authentic mac (unused trailing bits)", async () => {
    const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const [payload, mac] = (await issueGrant(SECRET, claims)).split(".");
    const last = ALPHABET.indexOf(mac.at(-1)!);
    expect(last % 4).toBe(0); // 43 chars carry 258 bits for a 256-bit mac
    for (const spare of [1, 2, 3]) {
      const variant = `${payload}.${mac.slice(0, -1)}${ALPHABET[last + spare]}`;
      expect(await verifyGrant(SECRET, variant)).toBeNull();
    }
  });

  it.each([
    ["empty", ""],
    ["no separator", "abcdef"],
    ["extra segment", "a.b.c"],
    ["empty mac", "abc."],
    ["empty payload", ".abc"],
    ["non-base64url mac", "abc.!!!!"],
    ["short mac", "abc.AAAA"],
    ["oversized", "a".repeat(4096) + "." + "b".repeat(43)],
  ])("rejects a malformed grant: %s", async (_name, grant) => {
    expect(await verifyGrant(SECRET, grant)).toBeNull();
  });

  it("rejects an authentic grant whose claims are not {hex token, known env}", async () => {
    const bad = [
      { t: "not-hex", e: "sandbox" },
      { t: TOKEN, e: "staging" },
      { t: TOKEN },
      "string",
    ];
    for (const c of bad) {
      expect(await verifyGrant(SECRET, await issueGrant(SECRET, c as never))).toBeNull();
    }
  });
});
