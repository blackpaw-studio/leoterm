import type { EmptyState, Meter, Node, RateLimit, Text, TextRun, UsageSnapshot } from "../../sdk/leo";
import { CATEGORIES, contextSegments, otherTokens } from "./categories";
import { formatModel, formatMoney, formatPercent, formatReset, formatTokens, shortenPath } from "./format";

/** What the plugin knows about the agent besides its usage. */
export interface Where {
  /** Home-relative or absolute working directory. */
  workspace?: string;
  branch?: string;
}

type Context = NonNullable<UsageSnapshot["context"]>;

const SEPARATOR = " · ";
/** Row labels are padded to one width so the values line up in a column. */
const LABEL_WIDTH = 9;
const LIMIT_LABELS: Readonly<Record<string, string>> = { five_hour: "session", seven_day: "weekly" };
const LIMIT_ORDER: readonly string[] = ["five_hour", "seven_day"];

const line = (...runs: TextRun[]): Text => ({ type: "Text", runs });
const dim = (text: string): TextRun => ({ text, tone: "secondary" });
const rowLabel = (name: string): TextRun => ({ text: name.padEnd(LABEL_WIDTH), tone: "secondary", mono: true });
const indent = (): TextRun => ({ text: " ".repeat(LABEL_WIDTH), mono: true });

/** Joins the parts' runs with " · " separators, skipping empty parts. */
const joined = (parts: TextRun[][]): TextRun[] =>
  parts.filter((p) => p.length > 0).flatMap((p, i) => (i === 0 ? p : [dim(SEPARATOR), ...p]));

/** A labelled row, or nothing when no part has anything to show. */
function row(name: string, parts: TextRun[][]): Text[] {
  const runs = joined(parts);
  return runs.length === 0 ? [] : [line(rowLabel(name), ...runs)];
}

function modelRow(usage: UsageSnapshot): Text[] {
  return row("model", [
    usage.model === undefined ? [] : [{ text: formatModel(usage.model), tone: "accent1", weight: "semibold" }],
    usage.effort === undefined ? [] : [dim(`thinking ${usage.effort}`)],
  ]);
}

function whereRow(usage: UsageSnapshot, where: Where): Text[] {
  const place = joined([
    where.workspace === undefined ? [] : [{ text: shortenPath(where.workspace), mono: true }],
    where.branch === undefined ? [] : [{ text: where.branch, tone: "accent3" }],
  ]);
  const git: TextRun[] =
    usage.git === undefined
      ? []
      : [
          { text: "(" },
          { text: `+${usage.git.added}`, tone: "success", mono: true },
          { text: "," },
          { text: `−${usage.git.removed}`, tone: "failure", mono: true },
          { text: ")" },
        ];
  // The git stats trail the place with a space, not a separator.
  const runs = place.length > 0 && git.length > 0 ? [...place, { text: " " }, ...git] : [...place, ...git];
  return runs.length === 0 ? [] : [line(rowLabel("where"), ...runs)];
}

function legend(context: Context): Text | undefined {
  const other = otherTokens(context);
  const items: TextRun[][] = [
    ...CATEGORIES.flatMap((c) => {
      const tokens = context.breakdown?.[c.key];
      return tokens === undefined ? [] : [[{ text: `${c.label} ${formatTokens(tokens)}`, tone: c.tone } satisfies TextRun]];
    }),
    ...(other <= 0 ? [] : [[dim(`${formatTokens(other)} other`)]]),
    ...(context.tokens <= context.window ? [[dim(`${formatTokens(context.window - context.tokens)} free`)]] : []),
    ...(context.compactAt === undefined ? [] : [[dim(`compacts at ${Math.round(context.compactAt * 100)}%`)]]),
  ];
  const runs = joined(items);
  return runs.length === 0 ? undefined : line(indent(), ...runs);
}

/**
 * The label row, the full-width meter (its label is the percentage, so the
 * percentage appears once, at the right) and the legend under the value column.
 * Without a window there is no meter, so the percentage moves to the label row.
 */
function contextRows(context: Context | undefined): Node[] {
  if (context === undefined) return [];
  const percent = formatPercent(context.percent, 1);
  const hasMeter = context.window > 0;
  const rows: Node[] = [line(rowLabel("context"), ...(hasMeter ? [] : [{ text: percent, mono: true } satisfies TextRun]))];
  if (hasMeter) {
    const bar: Meter = {
      type: "Meter",
      segments: contextSegments(context),
      max: context.window,
      label: percent,
      help: `${formatTokens(context.tokens)} / ${formatTokens(context.window)} tokens`,
    };
    rows.push(bar);
  }
  const key = legend(context);
  return key === undefined ? rows : [...rows, key];
}

const limitRank = (kind: string): number => {
  const i = LIMIT_ORDER.indexOf(kind);
  return i === -1 ? LIMIT_ORDER.length : i;
};

function limitParts(limit: RateLimit, nowMs: number): TextRun[] {
  const reset = formatReset(limit.resetsAt, nowMs);
  return [
    { text: LIMIT_LABELS[limit.kind] ?? limit.kind },
    { text: " " + formatPercent(limit.percentUsed, 1), mono: true },
    ...(reset === undefined ? [] : [dim(` resets ${reset}`)]),
  ];
}

/** Every limit and the cost on one line; gone when there is none. */
function limitsRow(usage: UsageSnapshot, nowMs: number): Text[] {
  const limits = [...(usage.rateLimits ?? [])].sort((a, b) => limitRank(a.kind) - limitRank(b.kind));
  const cost = usage.session === undefined ? [] : [[{ text: formatMoney(usage.session.costUsd), mono: true } satisfies TextRun]];
  return row("limits", [...limits.map((l) => limitParts(l, nowMs)), ...cost]);
}

const emptyState = (title: string, message?: string): EmptyState => ({ type: "EmptyState", title, ...(message === undefined ? {} : { message }) });

/** The expanded drawer. `null` means no data yet; `{}` means the harness reports no usage. */
export function buildBody(usage: UsageSnapshot | null, where: Where, nowMs: number): Node[] {
  if (usage === null) return [emptyState("No usage data yet", "This agent has not reported usage.")];
  if (Object.keys(usage).length === 0) return [emptyState("No usage data", "This agent's harness does not report usage.")];
  const rows: Node[] = [
    ...modelRow(usage),
    ...whereRow(usage, where),
    ...contextRows(usage.context),
    ...limitsRow(usage, nowMs),
  ];
  return rows.length === 0 ? [emptyState("No usage data yet")] : rows;
}
