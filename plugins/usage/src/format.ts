const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

export const percentText = (percent: number): string => Math.round(percent) + "%";

const pair = (big: number, unit: string, rest: number, restUnit: string): string =>
  rest === 0 ? big + unit : big + unit + " " + rest + restUnit;

const span = (ms: number): string => {
  if (ms < MIN) return "<1m";
  if (ms < HOUR) return Math.floor(ms / MIN) + "m";
  if (ms < DAY) return pair(Math.floor(ms / HOUR), "h", Math.floor((ms % HOUR) / MIN), "m");
  return pair(Math.floor(ms / DAY), "d", Math.floor((ms % DAY) / HOUR), "h");
};

export const resetsIn = (resetsAtMs: number, nowMs: number): string =>
  resetsAtMs <= nowMs ? "resetting now" : "resets in " + span(resetsAtMs - nowMs);

export const updatedAgo = (updatedAtMs: number, nowMs: number): string => {
  const age = Math.max(0, nowMs - updatedAtMs);
  if (age < MIN) return "Updated just now";
  if (age < HOUR) return "Updated " + Math.floor(age / MIN) + "m ago";
  if (age < DAY) return "Updated " + Math.floor(age / HOUR) + "h ago";
  return "Updated " + Math.floor(age / DAY) + "d ago";
};
