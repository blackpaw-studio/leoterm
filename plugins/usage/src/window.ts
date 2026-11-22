/** One rate-limit window of one account, normalised across providers. */
export interface UsageWindow {
  key: "session" | "weekly" | "weekly-opus" | "weekly-sonnet";
  label: string;
  /** 0…100. */
  percent: number;
  /** Epoch ms; absent when the provider gave no reset time. */
  resetsAtMs?: number;
}

export const clampPercent = (n: number): number => Math.min(100, Math.max(0, n));

export const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

export const finiteNumber = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

/** Builds a window, omitting `resetsAtMs` when unknown (keeps objects free of undefined keys). */
export const makeWindow = (key: UsageWindow["key"], label: string, percent: number, resetsAtMs?: number): UsageWindow =>
  resetsAtMs === undefined
    ? { key, label, percent: clampPercent(percent) }
    : { key, label, percent: clampPercent(percent), resetsAtMs };
