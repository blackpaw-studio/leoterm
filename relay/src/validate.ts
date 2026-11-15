import { APNS_TOKEN, type ApnsEnv, isApnsEnv } from "./grant";

/** Base64 text, i.e. a 1.5 KiB blob; Apple's payload ceiling is 4 KiB. */
export const MAX_CIPHERTEXT_CHARS = 2048;
const MAX_GRANT_CHARS = 1024;

const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const COLLAPSE_ID = /^[A-Za-z0-9._-]{1,64}$/; // APNs caps apns-collapse-id at 64 bytes

export interface RegisterInput {
  apnsToken: string;
  env: ApnsEnv;
}

export interface PushInput {
  grant: string;
  ciphertext: string;
  collapseId: string;
}

export type Parsed<T> =
  | { ok: true; value: T }
  | { ok: false; error: "bad_request" | "payload_too_large" };

const bad: Parsed<never> = { ok: false, error: "bad_request" };
const tooLarge: Parsed<never> = { ok: false, error: "payload_too_large" };

/** Parses a JSON object whose keys are exactly `keys`. Never echoes input. */
const parseObject = (text: string, keys: readonly string[]): Record<string, unknown> | null => {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const present = Object.keys(obj);
  return present.length === keys.length && keys.every((k) => k in obj) ? obj : null;
};

export const parseRegister = (text: string): Parsed<RegisterInput> => {
  const obj = parseObject(text, ["apns_token", "env"]);
  if (!obj) return bad;
  const token = typeof obj.apns_token === "string" ? obj.apns_token.toLowerCase() : "";
  if (!APNS_TOKEN.test(token) || !isApnsEnv(obj.env)) return bad;
  return { ok: true, value: { apnsToken: token, env: obj.env } };
};

export const parsePush = (text: string): Parsed<PushInput> => {
  const obj = parseObject(text, ["grant", "ciphertext", "collapse_id"]);
  if (!obj) return bad;
  const { grant, ciphertext, collapse_id: collapseId } = obj;
  if (typeof grant !== "string" || grant.length > MAX_GRANT_CHARS) return bad;
  if (typeof ciphertext !== "string" || !BASE64.test(ciphertext)) return bad;
  if (ciphertext.length > MAX_CIPHERTEXT_CHARS) return tooLarge;
  if (typeof collapseId !== "string" || !COLLAPSE_ID.test(collapseId)) return bad;
  return { ok: true, value: { grant, ciphertext, collapseId } };
};
