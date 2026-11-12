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

/** Meter segments for the present categories, or one total segment when the breakdown is unknown. */
export function contextSegments(context: NonNullable<UsageSnapshot["context"]>): MeterSegment[] {
  const present = CATEGORIES.flatMap((c) => {
    const value = context.breakdown?.[c.key];
    return value === undefined ? [] : [{ value, tone: c.tone }];
  });
  return present.length > 0 ? present : [{ value: context.tokens, tone: "accent1" }];
}
