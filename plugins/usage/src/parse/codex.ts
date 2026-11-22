import { finiteNumber, isRecord, makeWindow, type UsageWindow } from "../window";

const WINDOWS: ReadonlyArray<readonly [string, UsageWindow["key"], string]> = [
  ["primary_window", "session", "Session"],
  ["secondary_window", "weekly", "Weekly"],
];

/** Parses GET chatgpt.com/backend-api/wham/usage. Tolerant: anything unrecognised is skipped. */
export function parseCodex(body: unknown): UsageWindow[] {
  if (!isRecord(body) || !isRecord(body.rate_limit)) return [];
  const limit = body.rate_limit;
  return WINDOWS.flatMap(([field, key, label]) => {
    const w = limit[field];
    if (!isRecord(w)) return [];
    const percent = finiteNumber(w.used_percent);
    const resetAt = finiteNumber(w.reset_at);
    return percent === undefined ? [] : [makeWindow(key, label, percent, resetAt === undefined ? undefined : resetAt * 1000)];
  });
}
