import { finiteNumber, isRecord, makeWindow, type UsageWindow } from "../window";

/** Response field → window, in display order. Unknown fields are ignored. */
const WINDOWS: ReadonlyArray<readonly [string, UsageWindow["key"], string]> = [
  ["five_hour", "session", "Session"],
  ["seven_day", "weekly", "Weekly"],
  ["seven_day_opus", "weekly-opus", "Weekly Opus"],
  ["seven_day_sonnet", "weekly-sonnet", "Weekly Sonnet"],
];

const parseIso = (v: unknown): number | undefined => {
  if (typeof v !== "string") return undefined;
  const ms = Date.parse(v);
  return Number.isNaN(ms) ? undefined : ms;
};

/** Parses GET api.anthropic.com/api/oauth/usage. Tolerant: anything unrecognised is skipped. */
export function parseClaude(body: unknown): UsageWindow[] {
  if (!isRecord(body)) return [];
  return WINDOWS.flatMap(([field, key, label]) => {
    const w = body[field];
    if (!isRecord(w)) return [];
    const percent = finiteNumber(w.utilization);
    return percent === undefined ? [] : [makeWindow(key, label, percent, parseIso(w.resets_at))];
  });
}
