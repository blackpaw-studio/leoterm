import type { FetchResponse, Leo, TimerHandle } from "../../../sdk/leo";
import type { Clock } from "../clock";
import { OAUTH_SCOPE } from "../config";

const DEVICE_CODE_URL = "https://github.com/login/device/code";
const ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token";
const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";
/** The page the user enters the code on. Fixed here rather than taken from the response. */
export const VERIFICATION_URL = "https://github.com/login/device";

const SLOW_DOWN_STEP_SEC = 5;
const DEFAULT_INTERVAL_SEC = 5;
const MIN_INTERVAL_SEC = 1; // host minimum for leo.after
const USER_CODE_PATTERN = /^[A-Za-z0-9-]{4,32}$/;
const ERROR_CODE_PATTERN = /^[a-z_]{1,64}$/;

export type DeviceFlowState =
  | { readonly kind: "NotConfigured" }
  | { readonly kind: "Starting" }
  | { readonly kind: "AwaitingUser"; readonly userCode: string; readonly expiresAt: number }
  | { readonly kind: "Expired" }
  | { readonly kind: "Denied" }
  | { readonly kind: "Failed"; readonly message: string };

export interface DeviceFlowDeps {
  readonly leo: Pick<Leo, "fetch" | "after" | "log">;
  readonly clock: Clock;
  /** Empty means sign-in isn't configured in this build. */
  readonly clientId: string;
  readonly onState: (state: DeviceFlowState) => void;
  /** Called once with the access token on approval. Rejecting it fails the flow. */
  readonly onToken: (token: string) => Promise<void>;
  /** Wraps each network call (the scheduler's user lane). Defaults to a direct call. */
  readonly run?: <T>(task: () => Promise<T>) => Promise<T>;
}

export interface DeviceFlow {
  /** Begin (or restart) the flow. Any flow in progress is abandoned. */
  start(): Promise<void>;
  /** Stop polling and ignore any response still in flight. */
  cancel(): void;
}

type JsonObject = Record<string, unknown>;

const formBody = (fields: Readonly<Record<string, string>>): string =>
  Object.entries(fields)
    .map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v))
    .join("&");

const parseObject = (res: FetchResponse): JsonObject | null => {
  if (res.bodyEncoding !== "utf8") return null;
  try {
    const parsed: unknown = JSON.parse(res.body);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as JsonObject) : null;
  } catch {
    return null;
  }
};

const positiveNumber = (value: unknown, fallback: number): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;

const errorCode = (body: JsonObject | null): string | null =>
  typeof body?.error === "string" && ERROR_CODE_PATTERN.test(body.error) ? body.error : null;

export function createDeviceFlow(deps: DeviceFlowDeps): DeviceFlow {
  const { leo, clock, clientId, onState, onToken } = deps;
  const run = deps.run ?? (<T>(task: () => Promise<T>) => task());
  let generation = 0;
  let timer: TimerHandle | null = null;

  const post = (url: string, fields: Readonly<Record<string, string>>): Promise<FetchResponse> =>
    run(() =>
      leo.fetch(url, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
        body: formBody(fields),
      }),
    );

  const cancel = (): void => {
    generation += 1;
    timer?.cancel();
    timer = null;
  };

  async function poll(gen: number, intervalSec: number, deviceCode: string, expiresAt: number): Promise<void> {
    const live = (): boolean => gen === generation;
    const finish = (state: DeviceFlowState): void => {
      if (!live()) return;
      cancel();
      onState(state);
    };
    const again = (nextSec: number): void => {
      timer = leo.after(Math.max(MIN_INTERVAL_SEC, nextSec), () => poll(gen, nextSec, deviceCode, expiresAt));
    };

    if (!live()) return;
    if (clock.now() >= expiresAt) return finish({ kind: "Expired" });

    let res: FetchResponse;
    try {
      res = await post(ACCESS_TOKEN_URL, { client_id: clientId, device_code: deviceCode, grant_type: DEVICE_GRANT });
    } catch {
      // Transient (offline, host rate limit): keep going at the same pace until the code expires.
      if (live()) again(intervalSec);
      return;
    }
    if (!live()) return;

    const body = parseObject(res);
    if (typeof body?.access_token === "string" && body.access_token !== "") {
      const token = body.access_token;
      cancel();
      try {
        await onToken(token);
      } catch {
        onState({ kind: "Failed", message: "Couldn't save the GitHub token" });
      }
      return;
    }
    const code = errorCode(body);
    if (code === "authorization_pending") return again(intervalSec);
    if (code === "slow_down") return again(intervalSec + SLOW_DOWN_STEP_SEC);
    if (code === "expired_token") return finish({ kind: "Expired" });
    if (code === "access_denied") return finish({ kind: "Denied" });
    if (res.status >= 500) return again(intervalSec);
    finish({ kind: "Failed", message: code === null ? "Unexpected response from GitHub" : "GitHub rejected sign-in (" + code + ")" });
  }

  async function start(): Promise<void> {
    cancel();
    if (clientId === "") return onState({ kind: "NotConfigured" });
    const gen = generation;
    onState({ kind: "Starting" });

    let res: FetchResponse;
    try {
      res = await post(DEVICE_CODE_URL, { client_id: clientId, scope: OAUTH_SCOPE });
    } catch {
      if (gen === generation) onState({ kind: "Failed", message: "Couldn't reach GitHub" });
      return;
    }
    if (gen !== generation) return;

    const body = parseObject(res);
    const userCode = body?.user_code;
    const deviceCode = body?.device_code;
    if (typeof userCode !== "string" || !USER_CODE_PATTERN.test(userCode) || typeof deviceCode !== "string" || deviceCode === "") {
      const code = errorCode(body);
      return onState({
        kind: "Failed",
        message: code === null ? "Unexpected response from GitHub" : "GitHub rejected sign-in (" + code + ")",
      });
    }
    const expiresAt = clock.now() + positiveNumber(body?.expires_in, 900) * 1000;
    const intervalSec = positiveNumber(body?.interval, DEFAULT_INTERVAL_SEC);
    onState({ kind: "AwaitingUser", userCode, expiresAt });
    timer = leo.after(Math.max(MIN_INTERVAL_SEC, intervalSec), () => poll(gen, intervalSec, deviceCode, expiresAt));
  }

  return { start, cancel };
}
