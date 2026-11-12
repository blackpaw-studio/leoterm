import type { Meter, SlotRoot, Text, UsageSnapshot } from "../../sdk/leo";
import { contextSegments } from "./categories";
import { formatMoney, formatPercent, formatTokens } from "./format";

const SEPARATOR = " · ";

const plain = (text: string): Text => ({ type: "Text", runs: [{ text, tone: "secondary" }] });

const modelNode = (model: string): Text => ({ type: "Text", runs: [{ text: model, tone: "accent1", weight: "semibold" }] });

function meterNode(context: NonNullable<UsageSnapshot["context"]>): Meter | undefined {
  if (!(context.window > 0)) return undefined;
  return {
    type: "Meter",
    segments: contextSegments(context),
    max: context.window,
    help: `${formatTokens(context.tokens)} / ${formatTokens(context.window)} tokens`,
  };
}

/** The percentages and cost, joined as one mono run row; undefined when none are present. */
function figuresNode(usage: UsageSnapshot): Text | undefined {
  const fiveHour = usage.rateLimits?.find((l) => l.kind === "five_hour");
  const parts = [
    usage.context && formatPercent(usage.context.percent, 0),
    fiveHour && `5h ${formatPercent(fiveHour.percentUsed, 0)}`,
    usage.session && formatMoney(usage.session.costUsd),
  ].filter((p): p is string => typeof p === "string");
  return parts.length === 0 ? undefined : { type: "Text", runs: [{ text: parts.join(SEPARATOR), mono: true }] };
}

/**
 * The collapsed strip. `null` means no data yet; `{}` means the harness reports no usage.
 * Only Text and Meter nodes are used, as a pane summary accepts nothing else.
 */
export function buildSummary(usage: UsageSnapshot | null): SlotRoot {
  if (usage === null) return plain("—");
  if (Object.keys(usage).length === 0) return plain("No usage data");
  const nodes = [
    usage.model === undefined ? undefined : modelNode(usage.model),
    usage.context && meterNode(usage.context),
    figuresNode(usage),
  ].filter((n): n is Text | Meter => n !== undefined);
  return nodes.length === 0 ? plain("—") : nodes;
}
