/** Pure formatting helpers for the Status pane. No clock, no globals. */

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

const trimZero = (s: string): string => s.replace(/\.0$/, "");

/** One decimal below 10, none above. */
const scaled = (v: number): string => (v < 10 ? trimZero(v.toFixed(1)) : String(Math.round(v)));

/** `999`, `1k`, `3.1k`, `154k`, `1.2M`. */
export function formatTokens(n: number): string {
  if (n < 1000) return String(Math.round(n));
  const k = scaled(n / 1000);
  if (Number(k) < 1000) return `${k}k`;
  return `${scaled(n / 1_000_000)}M`;
}

export const formatPercent = (value: number, decimals: number): string => `${value.toFixed(decimals)}%`;

export const formatMoney = (usd: number): string => `$${usd.toFixed(2)}`;

/** Relative countdown to an ISO time: `3h 50m`, `4d 2h`, `12m`, `<1m`, `now`. Undefined when unparseable. */
export function formatReset(resetsAtISO: string, nowMs: number): string | undefined {
  const target = Date.parse(resetsAtISO);
  if (Number.isNaN(target)) return undefined;
  const ms = target - nowMs;
  if (ms <= 0) return "now";
  if (ms < MINUTE_MS) return "<1m";
  if (ms < HOUR_MS) return `${Math.floor(ms / MINUTE_MS)}m`;
  if (ms < DAY_MS) return `${Math.floor(ms / HOUR_MS)}h ${Math.floor((ms % HOUR_MS) / MINUTE_MS)}m`;
  return `${Math.floor(ms / DAY_MS)}d ${Math.floor((ms % DAY_MS) / HOUR_MS)}h`;
}

/** `~/.leo/agents/leoterm` -> `~/.l/a/leoterm`: middle components keep their first character (and a leading dot). */
export function shortenPath(path: string): string {
  const parts = path.split("/").filter((p) => p !== "");
  const head = path.startsWith("/") ? "/" : "";
  const abbreviate = (p: string): string => p.slice(0, p.startsWith(".") ? 2 : 1);
  const last = parts.length - 1;
  return head + parts.map((p, i) => (i === last || (i === 0 && p === "~") ? p : abbreviate(p))).join("/");
}
