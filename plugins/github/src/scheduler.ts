import type { Clock } from "./clock";
import type { Result } from "./github/errors";

/** Leo's host allows 4 fetches in flight and rejects (never queues) the fifth. */
export const MAX_IN_FLIGHT = 4;
/** The host's fetch quota per rolling minute, shared by both lanes. */
export const HOST_BUDGET_PER_MIN = 60;
/** Poll-lane share of the host quota, in requests; the other 20 stay free for the user lane. */
export const POLL_BUDGET_PER_MIN = 40;
/** Requests one agent's status refresh can make: PR lookup, check runs and commit statuses. */
export const POLL_REQUESTS_PER_STATUS = 3;
const WINDOW_MS = 60_000;

/** `Transport` reasons the gate produces. A poll task that gets one of these didn't fail: it was held back. */
export const BUDGET_REASON = "poll request budget spent for this minute";
export const PAUSED_REASON = "polling is paused";
export const HOST_BUDGET_REASON = "Leo's request limit for this minute is spent";

export type Lane = "user" | "poll";

export interface PollCycleOptions {
  /** Requests one key can make; a key only starts when the poll budget has this many left. Default 1. */
  readonly cost?: number;
}

export interface PollCycleResult<K extends string, T> {
  /** Settled keys. Excludes Transport failures (see `skipped`). */
  readonly results: ReadonlyMap<K, Result<T>>;
  /** Keys that failed with a Transport error. Skipped for this cycle, not surfaced to the user. */
  readonly skipped: readonly K[];
  /** Keys that didn't fit this minute's request budget. They go first next cycle. */
  readonly deferred: readonly K[];
  /** Keys never started because polling was paused. Not carried over. */
  readonly dropped: readonly K[];
}

export interface Scheduler {
  /**
   * Gate ONE host fetch on the user lane (view open, actions, sign-in): at most 4 in flight, user work
   * starts before queued poll work. Rejects with `HOST_BUDGET_REASON` when the host's 60/min is spent.
   * Wrap the `leo.fetch` call itself, never a task that makes several.
   */
  user<T>(fetch: () => Promise<T>): Promise<T>;
  /**
   * Gate ONE host fetch on the poll lane. Also rejects with `BUDGET_REASON` once 40 poll requests
   * started this rolling minute (or the host's 60 is spent), and with `PAUSED_REASON` while paused.
   */
  poll<T>(fetch: () => Promise<T>): Promise<T>;
  /**
   * One task per distinct key, run up to 4 at a time. A key only starts while the poll budget (in
   * requests) has `cost` left; the rest come back as `deferred` and go first next cycle (round-robin).
   * A `RateLimited` result pauses the lane until its `resetAt`.
   * The task makes its requests through a poll-lane client, which is what spends the budget.
   */
  pollCycle<K extends string, T>(
    keys: readonly K[],
    task: (key: K) => Promise<Result<T>>,
    options?: PollCycleOptions,
  ): Promise<PollCycleResult<K, T>>;
  /** Pause the poll lane until epoch ms `until`. Never shortens an existing pause. */
  pauseUntil(until: number): void;
  /** Epoch ms the poll lane stays paused until, or null when it isn't. */
  pausedUntil(): number | null;
}

interface Job {
  readonly lane: Lane;
  readonly start: () => void;
  readonly refuse: (reason: string) => void;
}

const dedupe = <K>(items: readonly K[]): K[] => [...new Set(items)];

export function createScheduler(clock: Clock): Scheduler {
  const queues: Record<Lane, Job[]> = { user: [], poll: [] };
  let inFlight = 0;
  let paused: number | null = null;
  /** Start times (epoch ms) of fetches admitted in the last rolling minute. */
  let starts: Array<{ readonly at: number; readonly lane: Lane }> = [];
  let carryOver: string[] = [];

  const pausedUntil = (): number | null => {
    if (paused !== null && paused <= clock.now()) paused = null;
    return paused;
  };

  const recent = (): void => {
    const cutoff = clock.now() - WINDOW_MS;
    starts = starts.filter((s) => s.at > cutoff);
  };

  const hostLeft = (): number => {
    recent();
    return Math.max(0, HOST_BUDGET_PER_MIN - starts.length);
  };

  const pollLeft = (): number => {
    const host = hostLeft(); // prunes `starts` to the rolling minute first
    const used = starts.filter((s) => s.lane === "poll").length;
    return Math.min(host, Math.max(0, POLL_BUDGET_PER_MIN - used));
  };

  const refusalFor = (lane: Lane): string | null => {
    if (hostLeft() === 0) return HOST_BUDGET_REASON;
    if (lane === "user") return null;
    if (pausedUntil() !== null) return PAUSED_REASON;
    return pollLeft() === 0 ? BUDGET_REASON : null;
  };

  function pump(): void {
    while (inFlight < MAX_IN_FLIGHT) {
      const next = queues.user.shift() ?? queues.poll.shift();
      if (!next) return;
      const refusal = refusalFor(next.lane);
      if (refusal !== null) {
        next.refuse(refusal);
        continue;
      }
      starts = [...starts, { at: clock.now(), lane: next.lane }];
      inFlight += 1;
      next.start();
    }
  }

  const gate =
    (lane: Lane) =>
    <T>(fetch: () => Promise<T>): Promise<T> =>
      new Promise<T>((resolve, reject) => {
        queues[lane].push({
          lane,
          refuse: (reason) => reject(new Error(reason)),
          start: () => {
            // `fetch()` may throw synchronously; either way the slot must free.
            void Promise.resolve()
              .then(fetch)
              .then(resolve, reject)
              .finally(() => {
                inFlight -= 1;
                pump();
              });
          },
        });
        pump();
      });

  /** Carried-over keys first (in carry order), then the rest in input order. */
  const rotate = <K extends string>(keys: readonly K[]): K[] => {
    const carried = carryOver.filter((k): k is K => keys.includes(k as K));
    return [...carried, ...keys.filter((k) => !carried.includes(k))];
  };

  const pollCycle: Scheduler["pollCycle"] = async <K extends string, T>(
    keys: readonly K[],
    task: (key: K) => Promise<Result<T>>,
    options: PollCycleOptions = {},
  ) => {
    const cost = Math.max(1, options.cost ?? 1);
    const queue = rotate(dedupe(keys));
    const results = new Map<K, Result<T>>();
    const skipped: K[] = [];
    const deferred: K[] = [];
    const dropped: K[] = [];

    const settle = (key: K, res: Result<T>): void => {
      const reason = !res.ok && res.error.kind === "Transport" ? res.error.reason : null;
      if (!res.ok && res.error.kind === "RateLimited") api.pauseUntil(res.error.resetAt);
      if (reason === BUDGET_REASON || reason === HOST_BUDGET_REASON) deferred.push(key);
      else if (reason === PAUSED_REASON) dropped.push(key);
      else if (reason !== null) skipped.push(key);
      else results.set(key, res);
    };

    // Tasks run side by side and spend the budget as they go, so reserve each key's cost up front.
    let unreserved = pollLeft();
    async function worker(): Promise<void> {
      for (let key = queue.shift(); key !== undefined; key = queue.shift()) {
        if (pausedUntil() !== null) dropped.push(key);
        else if (unreserved < cost) deferred.push(key);
        else {
          unreserved -= cost;
          settle(key, await task(key));
        }
      }
    }
    await Promise.all(Array.from({ length: MAX_IN_FLIGHT }, worker));

    // Keep what other cycles (statuses vs issues) deferred; this cycle's own deferrals go behind them.
    carryOver = [...carryOver.filter((k) => !keys.includes(k as K)), ...deferred];
    return { results, skipped, deferred, dropped };
  };

  const api: Scheduler = {
    user: gate("user"),
    poll: gate("poll"),
    pollCycle,
    pauseUntil: (until) => {
      paused = Math.max(pausedUntil() ?? 0, until);
    },
    pausedUntil,
  };
  return api;
}
