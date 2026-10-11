import { b64urlToBytes, bytesToB64url } from "./encoding";

export type ApnsEnv = "sandbox" | "production";

export interface GrantClaims {
  /** APNs device token, lowercase hex */
  t: string;
  e: ApnsEnv;
}

export const APNS_TOKEN = /^(?:[0-9a-f]{2}){32,100}$/;
export const isApnsEnv = (v: unknown): v is ApnsEnv => v === "sandbox" || v === "production";

const MAX_GRANT_LENGTH = 1024;
const MAC_BYTES = 32;
const encoder = new TextEncoder();

const hmacKey = (secret: string, usage: "sign" | "verify"): Promise<CryptoKey> =>
  crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [usage]);

/** grant = b64url(JSON{t,e}) + "." + b64url(HMAC-SHA256(secret, first part)) */
export const issueGrant = async (secret: string, claims: GrantClaims): Promise<string> => {
  const payload = bytesToB64url(encoder.encode(JSON.stringify(claims)));
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret, "sign"), encoder.encode(payload));
  return `${payload}.${bytesToB64url(new Uint8Array(mac))}`;
};

const parseClaims = (payload: Uint8Array): GrantClaims | null => {
  try {
    const raw: unknown = JSON.parse(new TextDecoder().decode(payload));
    if (typeof raw !== "object" || raw === null) return null;
    const { t, e } = raw as Record<string, unknown>;
    return typeof t === "string" && APNS_TOKEN.test(t) && isApnsEnv(e) ? { t, e } : null;
  } catch {
    return null;
  }
};

/** Claims of an authentic grant, or null for anything forged, malformed or signed under another secret. */
export const verifyGrant = async (secret: string, grant: string): Promise<GrantClaims | null> => {
  if (grant.length > MAX_GRANT_LENGTH) return null;
  const parts = grant.split(".");
  if (parts.length !== 2) return null;
  const [payload, mac] = parts;
  const macBytes = b64urlToBytes(mac);
  const payloadBytes = b64urlToBytes(payload);
  if (!macBytes || macBytes.length !== MAC_BYTES || !payloadBytes || payloadBytes.length === 0) return null;
  // subtle.verify compares the MAC in constant time
  const authentic = await crypto.subtle.verify("HMAC", await hmacKey(secret, "verify"), macBytes, encoder.encode(payload));
  return authentic ? parseClaims(payloadBytes) : null;
};
