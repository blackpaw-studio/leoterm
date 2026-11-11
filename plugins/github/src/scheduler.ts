import type { Clock } from "./clock";
import type { Result } from "./github/errors";

/** Leo's host allows 4 fetches in flight. */
export const MAX_IN_FLIGHT = 4;
/** Poll-lane share of the host's 60 req/min; the other 20 stay free for the user lane. */
export const POLL_BUDGET_PER_MIN = 40;
const WINDOW_MS = 60_000;

export interface PollCycleResult<K extends string, T> {
  /** Settled keys, in start order. Excludes Transport failures (see `skipped`). */
  readonly results: ReadonlyMap<K, Result<T>>;
  /** Keys that failed with a Transport error. Skipped for this cycle, not surfaced to the user. */
  readonly skipped: readonly K[];
  /** Keys that didn't fit this minute's budget. They go first next cycle. */
  readonly deferred: readonly K[];
  /** Keys never started because polling was paused. Not carried over. */
  readonly dropped: readonly K[];
}

export interface Scheduler {
  /** User lane: view open, actions, sign-in. Starts before any queued poll work. Not budgeted. */
  user<T>(task: () => Promise<T>): Promise<T>;
  /**
   * Poll lane: one `task` per distinct key, capped at `POLL_BUDGET_PER_MIN` starts per rolling minute.
   * Keys that don't fit are returned as `deferred` and ordered first on the next cycle (round-robin).
   * A `RateLimited` result pauses the lane until its `resetAt`.
   */
  pollCycle<K extends string, T>(
    keys: readonly K[],
    task: (key: K) => Promise<Result<T>>,
  ): Promise<PollCycleResult<K, T>>;
  /** Pause the poll lane until epoch ms `until`. Never shortens an existing pause. */
  pauseUntil(until: number): void;
  /** Epoch ms the poll lane stays paused until, or null when it isn't. */
  pausedUntil(): number | null;
}

type Job = () => Promise<void>;

const dedupe = <K>(items: readonly K[]): K[] => [...new Set(items)];

export function createScheduler(clock: Clock): Scheduler {
  const userQueue: Job[] = [];
  const pollQueue: Job[] = [];
  let inFlight = 0;
  let paused: number | null = null;
  let pollStarts: number[] = [];
  let carryOver: string[] = [];

  function pump(): void {
    while (inFlight < MAX_IN_FLIGHT) {
      const next = userQueue.shift() ?? pollQueue.shift();
      if (!next) return;
      inFlight += 1;
      void next().finally(() => {
        inFlight -= 1;
        pump();
      });
    }
  }

  const enqueue = <T>(queue: Job[], run: () => Promise<T>): Promise<T> =>
    new Promise<T>((resolve, reject) => {
      queue.push(() => run().then(resolve, reject));
      pump();
    });

  const pausedUntil = (): number | null => {
    if (paused !== null && paused <= clock.now()) paused = null;
    return paused;
  };

  const budgetLeft = (): number => {
    const cutoff = clock.now() - WINDOW_MS;
    pollStarts = pollStarts.filter((t) => t > cutoff);
    return Math.max(0, POLL_BUDGET_PER_MIN - pollStarts.length);
  };

  /** Carried-over keys first (in carry order), then the rest in input order. */
  const rotate = <K extends string>(keys: readonly K[]): K[] => {
    const carried = carryOver.filter((k): k is K => keys.includes(k as K));
    return [...carried, ...keys.filter((k) => !carried.includes(k))];
  };

  const pollCycle: Scheduler["pollCycle"] = async <K extends string, T>(
    keys: readonly K[],
    task: (key: K) => Promise<Result<T>>,
  ) => {
    const ordered = rotate(dedupe(keys));
    const batch = ordered.slice(0, budgetLeft());
    const deferred = ordered.slice(batch.length);
    carryOver = deferred;
    pollStarts = [...pollStarts, ...batch.map(() => clock.now())];

    const results = new Map<K, Result<T>>();
    const skipped: K[] = [];
    const dropped: K[] = [];
    await Promise.all(
      batch.map((key) =>
        enqueue(pollQueue, async () => {
          if (pausedUntil() !== null) {
            dropped.push(key);
            return;
          }
          const res = await task(key);
          if (!res.ok && res.error.kind === "RateLimited") api.pauseUntil(res.error.resetAt);
          if (!res.ok && res.error.kind === "Transport") skipped.push(key);
          else results.set(key, res);
        }),
      ),
    );
    return { results, skipped, deferred, dropped };
  };

  const api: Scheduler = {
    user: (task) => enqueue(userQueue, task),
    pollCycle,
    pauseUntil: (until) => {
      paused = Math.max(pausedUntil() ?? 0, until);
    },
    pausedUntil,
  };
  return api;
}
