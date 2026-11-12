/** Injected time source. Logic takes a Clock; only main.ts passes the real one. */
export interface Clock {
  /** Epoch milliseconds. */
  now(): number;
}

export const systemClock: Clock = { now: () => Date.now() };
