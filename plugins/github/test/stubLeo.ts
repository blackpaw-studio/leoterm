/**
 * Test double for the plugin host bridge (`Leo`, plugins/sdk/leo.d.ts).
 *
 *   const stub = createStubLeo();
 *   stub.route("GET", "https://api.github.com/user", { status: 200, body: { login: "x" } });
 *   createPlugin(stub.leo, stub.clock);          // code under test only sees `stub.leo`
 *   await stub.emit("activate");                 // drive host events
 *   stub.lastRender(slot);                       // inspect what was drawn
 *   await stub.tick(60);                         // advance virtual time, firing timers
 *
 * Behaviour:
 * - render: recorded in `renders` (in order); `rendersFor`/`lastRender` look up by slot.
 *   Slots are compared by their JSON form, so build them with the same key order.
 * - on/emit: handlers per event; `emit` awaits all of them and returns the first
 *   defined result (the CallbackResult for `callback`).
 * - fetch: routed by "METHOD url" (method upper-cased, default GET). `route(m, url, ...entries)`
 *   queues a sequence: calls consume entries in order and the last one repeats, so
 *   `route("GET", u, ok200, notModified304)` is a 200 followed by 304s. An entry is a
 *   `StubResponse` or `{ reject }` (the promise rejects, like the host's rate limit or a
 *   disallowed host). Unrouted requests reject loudly. Every call lands in `fetches`.
 * - host limits: like LeoPluginRateLimiter, a fetch is rejected (never queued) when 4 are already in
 *   flight or 60 were admitted in the last rolling minute. `hostRejections` records each rejection;
 *   `maxInFlight` is the high-water mark. Rejections reject the promise, like the real host.
 * - secrets: backed by the `secretStore` Map.
 * - agents.list: returns a copy of the array set via `setAgents`.
 * - timer/after: virtual time only. `tick(sec)` advances `clock` and runs due callbacks in
 *   order, awaiting each. Enforces the host's minimums (timer >= 60 s, after >= 1 s).
 *   The host's "after only runs while a slot is visible" rule is not modelled.
 * - log: recorded in `logs`.
 */
import type {
  AgentSnapshot,
  Events,
  FetchInit,
  FetchResponse,
  JSONValue,
  Leo,
  SlotID,
  SlotRoot,
  TimerHandle,
} from "../../sdk/leo";
import type { Clock } from "../src/clock";

export interface StubResponse {
  status?: number;
  headers?: Record<string, string>;
  /** Strings go through verbatim; anything else is JSON-stringified. */
  body?: string | JSONValue;
  bodyEncoding?: "utf8" | "base64";
}
export interface StubRejection {
  reject: string;
}
export type StubEntry = StubResponse | StubRejection;

export interface RecordedFetch {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: string | undefined;
}
export interface RecordedRender {
  slot: SlotID;
  tree: SlotRoot;
}
export interface RecordedLog {
  level: string;
  message: string;
}

export interface StubClock extends Clock {
  /** Move time forward without firing timers (tick() does both). */
  advance(ms: number): void;
}

export interface StubLeo {
  /** Pass this to the code under test. */
  readonly leo: Leo;
  readonly clock: StubClock;
  readonly renders: readonly RecordedRender[];
  readonly fetches: readonly RecordedFetch[];
  readonly logs: readonly RecordedLog[];
  /** Fetches the modelled host refused (over 4 in flight, or over 60 in a rolling minute). */
  readonly hostRejections: readonly string[];
  /** Highest number of fetches in flight at once. */
  readonly maxInFlight: number;
  readonly secretStore: Map<string, string>;
  rendersFor(slot: SlotID): readonly SlotRoot[];
  lastRender(slot: SlotID): SlotRoot | undefined;
  route(method: string, url: string, ...entries: StubEntry[]): void;
  setAgents(agents: readonly AgentSnapshot[]): void;
  emit<E extends keyof Events>(event: E, ...args: Parameters<Events[E]>): Promise<Awaited<ReturnType<Events[E]>> | undefined>;
  /** Advance virtual time by `sec` seconds, running due timers in order. */
  tick(sec: number): Promise<void>;
}

export const START_MS = Date.UTC(2026, 0, 1, 12, 0, 0);

const HOST_MAX_IN_FLIGHT = 4;
const HOST_MAX_PER_WINDOW = 60;
const HOST_WINDOW_MS = 60_000;
const MIN_TIMER_SEC = 60;
const MIN_AFTER_SEC = 1;

const slotKey = (slot: SlotID): string => JSON.stringify(slot);
const routeKey = (method: string, url: string): string => method.toUpperCase() + " " + url;

const toFetchResponse = (entry: StubResponse): FetchResponse => {
  const body = entry.body ?? "";
  return {
    status: entry.status ?? 200,
    headers: entry.headers ?? {},
    body: typeof body === "string" ? body : JSON.stringify(body),
    bodyEncoding: entry.bodyEncoding ?? "utf8",
  };
};

interface ScheduledTimer {
  due: number;
  intervalSec: number | null;
  fn: () => void | Promise<void>;
  cancelled: boolean;
}

export function createStubLeo(startMs: number = START_MS): StubLeo {
  let nowMs = startMs;
  const clock: StubClock = {
    now: () => nowMs,
    advance: (ms) => {
      nowMs += ms;
    },
  };

  const renders: RecordedRender[] = [];
  const fetches: RecordedFetch[] = [];
  const logs: RecordedLog[] = [];
  const hostRejections: string[] = [];
  let admitted: number[] = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const secretStore = new Map<string, string>();
  const handlers = new Map<keyof Events, Array<Events[keyof Events]>>();
  const routes = new Map<string, { entries: StubEntry[]; next: number }>();
  const timers: ScheduledTimer[] = [];
  let agents: AgentSnapshot[] = [];

  const schedule = (sec: number, intervalSec: number | null, fn: () => void | Promise<void>): TimerHandle => {
    const timer: ScheduledTimer = { due: nowMs + sec * 1000, intervalSec, fn, cancelled: false };
    timers.push(timer);
    return {
      cancel: () => {
        timer.cancelled = true;
      },
    };
  };

  const leo: Leo = {
    render: (slot, tree) => {
      renders.push({ slot, tree });
    },
    on: (event, fn) => {
      handlers.set(event, [...(handlers.get(event) ?? []), fn]);
    },
    fetch: async (url: string, init: FetchInit = {}) => {
      const method = (init.method ?? "GET").toUpperCase();
      fetches.push({ method, url, headers: { ...(init.headers ?? {}) }, body: init.body });
      admitted = admitted.filter((t) => nowMs - t < HOST_WINDOW_MS);
      const refusal =
        admitted.length >= HOST_MAX_PER_WINDOW ? "rate limited" : inFlight >= HOST_MAX_IN_FLIGHT ? "too many in flight" : null;
      if (refusal !== null) {
        hostRejections.push(refusal + ": " + routeKey(method, url));
        throw new Error("stubLeo host: " + refusal);
      }
      admitted.push(nowMs);
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      try {
        await Promise.resolve(); // hold the slot across a turn, so concurrent callers overlap
        const route = routes.get(routeKey(method, url));
        if (!route) throw new Error("stubLeo: no route for " + routeKey(method, url));
        const entry = route.entries[Math.min(route.next, route.entries.length - 1)];
        route.next += 1;
        if ("reject" in entry) throw new Error(entry.reject);
        return toFetchResponse(entry);
      } finally {
        inFlight -= 1;
      }
    },
    secrets: {
      get: async (key) => secretStore.get(key) ?? null,
      set: async (key, value) => {
        secretStore.set(key, value);
        return null;
      },
      delete: async (key) => {
        secretStore.delete(key);
        return null;
      },
    },
    agents: { list: async () => agents.map((a) => ({ ...a })), usage: async () => null },
    timer: (intervalSec, fn) => {
      if (intervalSec < MIN_TIMER_SEC) throw new Error("stubLeo: timer interval must be >= " + MIN_TIMER_SEC);
      return schedule(intervalSec, intervalSec, fn);
    },
    after: (sec, fn) => {
      if (sec < MIN_AFTER_SEC) throw new Error("stubLeo: after delay must be >= " + MIN_AFTER_SEC);
      return schedule(sec, null, fn);
    },
    log: (level, message) => {
      logs.push({ level, message });
    },
  };

  const nextDue = (limit: number): ScheduledTimer | undefined =>
    timers
      .filter((t) => !t.cancelled && t.due <= limit)
      .reduce<ScheduledTimer | undefined>((best, t) => (best && best.due <= t.due ? best : t), undefined);

  return {
    leo,
    clock,
    renders,
    fetches,
    logs,
    hostRejections,
    get maxInFlight() {
      return maxInFlight;
    },
    secretStore,
    rendersFor: (slot) => renders.filter((r) => slotKey(r.slot) === slotKey(slot)).map((r) => r.tree),
    lastRender: (slot) => renders.filter((r) => slotKey(r.slot) === slotKey(slot)).pop()?.tree,
    route: (method, url, ...entries) => {
      if (entries.length === 0) throw new Error("stubLeo: route needs at least one entry");
      routes.set(routeKey(method, url), { entries, next: 0 });
    },
    setAgents: (list) => {
      agents = list.map((a) => ({ ...a }));
    },
    emit: (async (event: keyof Events, ...args: unknown[]) => {
      const results = await Promise.all(
        (handlers.get(event) ?? []).map((fn) => (fn as (...a: unknown[]) => unknown)(...args)),
      );
      return results.find((r) => r !== undefined);
    }) as StubLeo["emit"],
    tick: async (sec) => {
      const target = nowMs + sec * 1000;
      for (let t = nextDue(target); t; t = nextDue(target)) {
        nowMs = Math.max(nowMs, t.due);
        if (t.intervalSec === null) t.cancelled = true;
        else t.due += t.intervalSec * 1000;
        await t.fn();
      }
      nowMs = target;
    },
  };
}
