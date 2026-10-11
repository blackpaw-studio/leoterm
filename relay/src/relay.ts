import { type ApnsClient, createApnsClient } from "./apns";
import { issueGrant, verifyGrant } from "./grant";
import { type JwtProvider, createJwtProvider } from "./jwt";
import { parsePush, parseRegister } from "./validate";

export interface Env {
  APNS_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  GRANT_SECRET: string;
  REGISTER_LIMITER: RateLimit;
  PUSH_LIMITER: RateLimit;
}

export interface RelayDeps {
  fetch: typeof globalThis.fetch;
  /** milliseconds since epoch */
  now: () => number;
}

type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "not_found"
  | "payload_too_large"
  | "gone"
  | "rate_limited"
  | "upstream_error"
  | "internal";

const ERROR_STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  not_found: 404,
  payload_too_large: 413,
  gone: 410,
  rate_limited: 429,
  upstream_error: 502,
  internal: 500,
};

const respond = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const fail = (code: ErrorCode): Response => respond(ERROR_STATUS[code], { error: code });

const REQUIRED_SECRETS = ["APNS_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "GRANT_SECRET"] as const;
const hasSecrets = (env: Env): boolean => REQUIRED_SECRETS.every((k) => typeof env[k] === "string" && env[k] !== "");

const register = async (req: Request, env: Env): Promise<Response> => {
  const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
  if (!(await env.REGISTER_LIMITER.limit({ key: ip })).success) return fail("rate_limited");
  const parsed = parseRegister(await req.text());
  if (!parsed.ok) return fail(parsed.error);
  const grant = await issueGrant(env.GRANT_SECRET, { t: parsed.value.apnsToken, e: parsed.value.env });
  return respond(200, { grant });
};

const push = async (req: Request, env: Env, apns: ApnsClient): Promise<Response> => {
  const parsed = parsePush(await req.text());
  if (!parsed.ok) return fail(parsed.error);
  const { grant, ciphertext, collapseId } = parsed.value;

  const claims = await verifyGrant(env.GRANT_SECRET, grant);
  if (!claims) return fail("unauthorized");
  if (!(await env.PUSH_LIMITER.limit({ key: grant })).success) return fail("rate_limited");

  const outcome = await apns.send(
    { token: claims.t, env: claims.e, collapseId, ciphertext },
    { p8: env.APNS_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID },
  );
  if (outcome === "delivered") return respond(202, {});
  return fail(outcome === "gone" ? "gone" : "upstream_error");
};

/** Builds the Worker's fetch handler. The JWT cache lives as long as the returned handler. */
export const createRelay = (deps: RelayDeps, jwt: JwtProvider = createJwtProvider({ now: deps.now })) => {
  const apns = createApnsClient({ fetch: deps.fetch, jwt });
  return async (req: Request, env: Env): Promise<Response> => {
    const { pathname } = new URL(req.url);
    if (req.method !== "POST" || (pathname !== "/register" && pathname !== "/push")) return fail("not_found");
    if (!hasSecrets(env)) return fail("internal");
    try {
      return pathname === "/register" ? await register(req, env) : await push(req, env, apns);
    } catch (err) {
      // Name only: messages from fetch/crypto can embed URLs (device tokens).
      console.error("relay error", err instanceof Error ? err.name : "unknown");
      return fail("internal");
    }
  };
};
