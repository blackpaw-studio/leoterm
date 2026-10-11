import type { ApnsEnv } from "./grant";
import type { JwtCredentials, JwtProvider } from "./jwt";

export const APNS_TOPIC = "studio.blackpaw.leo.ios";
const APNS_TIMEOUT_MS = 8000;
const HOSTS: Record<ApnsEnv, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};
/** Apple reasons that mean "this device token is dead". */
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered"]);
/** Apple reasons that mean our provider token is no good. */
const BAD_PROVIDER_REASONS = new Set(["ExpiredProviderToken", "InvalidProviderToken"]);

export interface ApnsPush {
  token: string;
  env: ApnsEnv;
  collapseId: string;
  ciphertext: string;
}

export type ApnsOutcome = "delivered" | "gone" | "rejected";

export interface ApnsClient {
  send(push: ApnsPush, creds: JwtCredentials): Promise<ApnsOutcome>;
}

const reasonOf = async (res: Response): Promise<string | null> => {
  try {
    const body: unknown = await res.json();
    const reason = (body as { reason?: unknown } | null)?.reason;
    return typeof reason === "string" ? reason : null;
  } catch {
    return null;
  }
};

const buildRequest = ({ collapseId, ciphertext }: ApnsPush, authorization: string): RequestInit => ({
  method: "POST",
  headers: {
    authorization,
    "apns-topic": APNS_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-collapse-id": collapseId,
    "content-type": "application/json",
  },
  body: JSON.stringify({
    aps: {
      alert: { title: "Leo", body: "An agent needs you" },
      "mutable-content": 1,
      sound: "default",
      "thread-id": collapseId,
    },
    c: ciphertext,
  }),
  signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
});

export const createApnsClient = ({ fetch, jwt }: { fetch: typeof globalThis.fetch; jwt: JwtProvider }): ApnsClient => ({
  async send(push, creds) {
    // Signing failures are our fault and propagate (-> 500); transport failures are Apple's (-> 502).
    const authorization = `bearer ${await jwt.get(creds)}`;
    let res: Response;
    try {
      res = await fetch(`https://${HOSTS[push.env]}/3/device/${push.token}`, buildRequest(push, authorization));
    } catch {
      return "rejected";
    }
    if (res.ok) return "delivered";
    const reason = await reasonOf(res);
    if (res.status === 410 || (reason !== null && DEAD_TOKEN_REASONS.has(reason))) return "gone";
    if (reason !== null && BAD_PROVIDER_REASONS.has(reason)) jwt.invalidate();
    return "rejected";
  },
});
