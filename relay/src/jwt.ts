// Hand-rolled APNs provider-token (ES256 JWT) signing with WebCrypto. No deps.

import { bytesToB64url } from "./encoding";

const encoder = new TextEncoder();

const jsonToB64url = (value: unknown): string => bytesToB64url(encoder.encode(JSON.stringify(value)));

const pemToPkcs8 = (pem: string): Uint8Array => {
  const b64 = pem
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
};

/** Read one DER INTEGER at `offset`; returns its value left-padded/stripped to 32 bytes. */
const readInteger = (der: Uint8Array, offset: number): { value: Uint8Array; next: number } => {
  if (der[offset] !== 0x02) throw new Error("DER: expected INTEGER");
  const len = der[offset + 1];
  let int = der.slice(offset + 2, offset + 2 + len);
  while (int.length > 32 && int[0] === 0) int = int.slice(1);
  if (int.length > 32) throw new Error("DER: integer too large for P-256");
  const value = new Uint8Array(32);
  value.set(int, 32 - int.length);
  return { value, next: offset + 2 + len };
};

/** Convert an ASN.1 DER ECDSA signature to the raw r||s (64 byte) form JWS requires. */
export const derToRawEs256 = (der: Uint8Array): Uint8Array => {
  if (der[0] !== 0x30) throw new Error("DER: expected SEQUENCE");
  const bodyStart = der[1] & 0x80 ? 2 + (der[1] & 0x7f) : 2;
  const r = readInteger(der, bodyStart);
  const s = readInteger(der, r.next);
  const raw = new Uint8Array(64);
  raw.set(r.value, 0);
  raw.set(s.value, 32);
  return raw;
};

export interface JwtInput {
  p8: string;
  keyId: string;
  teamId: string;
  /** seconds since epoch; injected for testability */
  now: number;
}

export const signApnsJwt = async ({ p8, keyId, teamId, now }: JwtInput): Promise<string> => {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(p8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signingInput = `${jsonToB64url({ alg: "ES256", kid: keyId })}.${jsonToB64url({ iss: teamId, iat: now })}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput)),
  );
  // WebCrypto already returns raw r||s (64 bytes); only convert if a DER signature appears.
  const raw = sig.length === 64 ? sig : derToRawEs256(sig);
  return `${signingInput}.${bytesToB64url(raw)}`;
};

/** APNs wants a provider token refreshed no more than every 20 min and no older than 60 min. */
export const JWT_MAX_AGE_SECONDS = 40 * 60;

export interface JwtCredentials {
  p8: string;
  keyId: string;
  teamId: string;
}

export interface JwtProviderOptions {
  /** milliseconds since epoch */
  now: () => number;
  sign?: (input: JwtInput) => Promise<string>;
}

export interface JwtProvider {
  get(creds: JwtCredentials): Promise<string>;
  /** Forget the cached token (call when Apple rejects it). */
  invalidate(): void;
}

interface CacheEntry {
  fingerprint: string;
  signedAtMs: number;
  token: Promise<string>;
}

/** Caches one signed token (as a promise, so concurrent callers share a single signing). */
export const createJwtProvider = ({ now, sign = signApnsJwt }: JwtProviderOptions): JwtProvider => {
  let entry: CacheEntry | null = null;
  return {
    get(creds) {
      const nowMs = now();
      const fingerprint = `${creds.keyId}|${creds.teamId}|${creds.p8}`;
      if (entry && entry.fingerprint === fingerprint && nowMs - entry.signedAtMs < JWT_MAX_AGE_SECONDS * 1000) {
        return entry.token;
      }
      const token = sign({ ...creds, now: Math.floor(nowMs / 1000) });
      const created = { fingerprint, signedAtMs: nowMs, token };
      entry = created;
      token.catch(() => {
        if (entry === created) entry = null;
      });
      return token;
    },
    invalidate() {
      entry = null;
    },
  };
};
