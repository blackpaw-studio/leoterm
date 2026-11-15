import type { MeterSegment, Tone, UsageSnapshot } from "../../sdk/leo";

type Breakdown = NonNullable<NonNullable<UsageSnapshot["context"]>["breakdown"]>;

export interface Category {
  key: keyof Breakdown;
  /** Short legend label. */
  label: string;
  tone: Tone;
}

/** Context categories in meter order, each with its fixed tone. */
export const CATEGORIES: readonly Category[] = [
  { key: "system", label: "sys", tone: "accent1" },
  { key: "tools", label: "tools", tone: "accent2" },
  { key: "mcp", label: "mcp", tone: "accent3" },
  { key: "memory", label: "mem", tone: "accent4" },
  { key: "messages", label: "chat", tone: "accent5" },
];

type Context = NonNullable<UsageSnapshot["context"]>;

/** Tokens in use that no known breakdown category accounts for (0 without a breakdown). */
export function otherTokens(context: Context): number {
  if (context.breakdown === undefined) return 0;
  const known = CATEGORIES.reduce((sum, c) => sum + (context.breakdown?.[c.key] ?? 0), 0);
  return Math.max(0, context.tokens - known);
}

/**
 * Meter segments for the present categories plus an "other" remainder, so the bar
 * matches the percentage label; one total segment when the breakdown is unknown.
 */
export function contextSegments(context: Context): MeterSegment[] {
  const present = CATEGORIES.flatMap((c) => {
    const value = context.breakdown?.[c.key];
    return value === undefined ? [] : [{ value, tone: c.tone }];
  });
  if (present.length === 0) return [{ value: context.tokens, tone: "accent1" }];
  const other = otherTokens(context);
  return other > 0 ? [...present, { value: other, tone: "secondary" }] : present;
}
