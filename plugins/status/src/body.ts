import type { EmptyState, Meter, Node, RateLimit, Text, TextRun, UsageSnapshot } from "../../sdk/leo";
import { CATEGORIES, contextSegments } from "./categories";
import { formatMoney, formatPercent, formatReset, formatTokens, shortenPath } from "./format";

/** What the plugin knows about the agent besides its usage. */
export interface Where {
  /** Home-relative or absolute working directory. */
  workspace?: string;
  branch?: string;
}

type Context = NonNullable<UsageSnapshot["context"]>;

const GAP = "  ";
const SEPARATOR = " · ";
const LIMIT_LABELS: Readonly<Record<string, string>> = { five_hour: "session", seven_day: "weekly" };
const LIMIT_ORDER: readonly string[] = ["five_hour", "seven_day"];

const line = (...runs: TextRun[]): Text => ({ type: "Text", runs });
const label = (text: string): TextRun => ({ text, tone: "secondary" });
const gap = (): TextRun => ({ text: GAP });
const present = (runs: Array<TextRun | undefined>): TextRun[] => runs.filter((r): r is TextRun => r !== undefined);

function modelRow(usage: UsageSnapshot): Text[] {
  if (usage.model === undefined && usage.effort === undefined) return [];
  return [
    line(
      ...present([
        label("Model" + GAP),
        usage.model === undefined ? undefined : { text: usage.model, tone: "accent1", weight: "semibold" },
        usage.model !== undefined && usage.effort !== undefined ? gap() : undefined,
        usage.effort === undefined ? undefined : label(`thinking ${usage.effort}`),
      ]),
    ),
  ];
}

function whereRow(usage: UsageSnapshot, where: Where): Text[] {
  const candidates: TextRun[][] = [
    where.workspace === undefined ? [] : [{ text: shortenPath(where.workspace), mono: true }],
    where.branch === undefined ? [] : [{ text: where.branch, tone: "accent3" }],
    usage.git === undefined
      ? []
      : [
          { text: "(" },
          { text: `+${usage.git.added}`, tone: "success", mono: true },
          { text: "," },
          { text: `−${usage.git.removed}`, tone: "failure", mono: true },
          { text: ")" },
        ],
  ];
  const parts = candidates.filter((p) => p.length > 0);
  if (parts.length === 0) return [];
  return [line(label("Where" + GAP), ...parts.flatMap((p, i) => (i === 0 ? p : [gap(), ...p])))];
}

function legend(context: Context): Text | undefined {
  const items: TextRun[] = [
    ...CATEGORIES.flatMap((c) => {
      const tokens = context.breakdown?.[c.key];
      return tokens === undefined ? [] : [{ text: `${c.label} ${formatTokens(tokens)}`, tone: c.tone } satisfies TextRun];
    }),
    ...(context.tokens <= context.window ? [{ text: `free ${formatTokens(context.window - context.tokens)}`, tone: "secondary" } satisfies TextRun] : []),
    ...(context.compactAt === undefined ? [] : [{ text: `compacts at ${Math.round(context.compactAt * 100)}%`, tone: "secondary" } satisfies TextRun]),
  ];
  if (items.length === 0) return undefined;
  return line(...items.flatMap((r, i) => (i === 0 ? [r] : [label(SEPARATOR), r])));
}

function contextRows(context: Context | undefined): Node[] {
  if (context === undefined) return [];
  const percent = formatPercent(context.percent, 1);
  const rows: Node[] = [line(label("Context" + GAP), { text: percent, mono: true })];
  if (context.window > 0) {
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

function limitLine(limit: RateLimit, nowMs: number): Text {
  const reset = formatReset(limit.resetsAt, nowMs);
  return line(
    ...present([
      { text: LIMIT_LABELS[limit.kind] ?? limit.kind },
      { text: " " + formatPercent(limit.percentUsed, 1), mono: true },
      reset === undefined ? undefined : label(` resets ${reset}`),
    ]),
  );
}

function limitRows(usage: UsageSnapshot, nowMs: number): Node[] {
  const limits = [...(usage.rateLimits ?? [])].sort((a, b) => limitRank(a.kind) - limitRank(b.kind));
  const cost = usage.session === undefined ? [] : [line(label("cost "), { text: formatMoney(usage.session.costUsd), mono: true })];
  const rows = [...limits.map((l) => limitLine(l, nowMs)), ...cost];
  return rows.length === 0 ? [] : [line(label("Limits")), ...rows];
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
    ...limitRows(usage, nowMs),
  ];
  return rows.length === 0 ? [emptyState("No usage data yet")] : rows;
}
