import type { UsageWindow } from "./window";

export type AccountStatus = "loading" | "ok" | "stale" | "expired" | "needsAuthorization" | "error";

export interface AccountState {
  status: AccountStatus;
  /** Last good windows. Empty while loading, expired, locked or when the provider reported none. */
  windows: readonly UsageWindow[];
  /** Epoch ms of the last good fetch. */
  updatedAtMs?: number;
  /** Failure reason for stale/error states. */
  message?: string;
  /** Epoch ms before which the poller leaves this account alone (after a 429). */
  backoffUntilMs?: number;
}

export type Outcome =
  | { kind: "ok"; windows: readonly UsageWindow[] }
  | { kind: "unauthorized" }
  | { kind: "needsAuthorization" }
  | { kind: "rateLimited" }
  | { kind: "failed"; message: string };

export const BACKOFF_MS = 15 * 60_000;
export const NO_DATA = "No usage data";

export const initialState = (): AccountState => ({ status: "loading", windows: [] });

/** A failure keeps the last good values (stale) or, with none, becomes an error. */
const degrade = (state: AccountState, message: string, extra: Partial<AccountState> = {}): AccountState =>
  state.windows.length > 0
    ? { ...state, ...extra, status: "stale", message }
    : { windows: [], ...extra, status: "error", message };

export function reduce(state: AccountState, outcome: Outcome, nowMs: number): AccountState {
  switch (outcome.kind) {
    case "ok":
      return outcome.windows.length === 0
        ? { status: "error", windows: [], message: NO_DATA }
        : { status: "ok", windows: outcome.windows, updatedAtMs: nowMs };
    case "unauthorized":
      return { status: "expired", windows: [] };
    case "needsAuthorization":
      return { status: "needsAuthorization", windows: [] };
    case "rateLimited":
      return degrade(state, "Rate limited", { backoffUntilMs: nowMs + BACKOFF_MS });
    case "failed":
      return degrade(state, outcome.message);
  }
}

export const isDue = (state: AccountState, nowMs: number): boolean =>
  state.backoffUntilMs === undefined || nowMs >= state.backoffUntilMs;
