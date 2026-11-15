import type { Env } from "../src/relay";

export const SECRET = "unit-test-grant-secret";
export const TOKEN = "ab".repeat(32);
export const COLLAPSE_ID = "0123456789abcdef0123456789abcdef";
export const CIPHERTEXT = "Q2lwaGVydGV4dEJ5dGVzMTIzNDU2Nzg5MA==";

export const b64urlToBytes = (s: string): Uint8Array =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
export const b64urlToJson = (s: string) => JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));

export const toPem = (pkcs8: ArrayBuffer): string => {
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  return `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
};

export interface TestKey {
  pem: string;
  publicKey: CryptoKey;
}

export const makeKey = async (): Promise<TestKey> => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  return { pem: toPem((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer), publicKey: pair.publicKey };
};

export interface FakeLimiter extends RateLimit {
  keys: string[];
}

export const fakeLimiter = (allow = true): FakeLimiter => {
  const keys: string[] = [];
  return {
    keys,
    limit: async ({ key }) => {
      keys.push(key);
      return { success: allow };
    },
  };
};

export const makeEnv = (pem: string, overrides: Partial<Env> = {}): Env => ({
  APNS_P8: pem,
  APNS_KEY_ID: "ABC123DEFG",
  APNS_TEAM_ID: "TEAM123456",
  GRANT_SECRET: SECRET,
  REGISTER_LIMITER: fakeLimiter(),
  PUSH_LIMITER: fakeLimiter(),
  ...overrides,
});

export const post = (path: string, body: unknown, headers: Record<string, string> = {}): Request =>
  new Request(`https://relay.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

export interface ApnsCall {
  url: string;
  method: string;
  headers: Headers;
  body: string;
}

export interface FakeApns {
  calls: ApnsCall[];
  fetch: typeof fetch;
}

/** Records every outbound request; answers with `respond(callIndex)`. */
export const fakeApns = (respond: (n: number) => Response | Promise<Response> = () => new Response(null, { status: 200 })): FakeApns => {
  const calls: ApnsCall[] = [];
  return {
    calls,
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({
        url: String(input),
        method: init?.method ?? "GET",
        headers: new Headers(init?.headers),
        body: String(init?.body ?? ""),
      });
      return respond(calls.length - 1);
    }) as typeof fetch,
  };
};

export const apnsError = (status: number, reason: string): Response =>
  new Response(JSON.stringify({ reason }), { status, headers: { "content-type": "application/json" } });
