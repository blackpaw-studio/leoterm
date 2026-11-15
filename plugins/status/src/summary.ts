import type { SlotRoot, Text, UsageSnapshot } from "../../sdk/leo";
import { formatModel, formatPercent } from "./format";

const SEPARATOR = " · ";

const plain = (text: string): Text => ({ type: "Text", runs: [{ text, tone: "secondary" }] });

/** The model in accent, followed by the reasoning effort when known. */
const modelNode = (model: string, effort: string | undefined): Text => ({
  type: "Text",
  runs: [
    { text: formatModel(model), tone: "accent1", weight: "semibold" },
    ...(effort === undefined ? [] : [{ text: `${SEPARATOR}${effort}`, tone: "secondary" as const }]),
  ],
});

/** The context and five-hour percentages joined as one mono run row; undefined when none are present. */
function figuresNode(usage: UsageSnapshot): Text | undefined {
  const fiveHour = usage.rateLimits?.find((l) => l.kind === "five_hour");
  const parts = [
    usage.context && formatPercent(usage.context.percent, 0),
    fiveHour && `5h ${formatPercent(fiveHour.percentUsed, 0)}`,
  ].filter((p): p is string => typeof p === "string");
  return parts.length === 0 ? undefined : { type: "Text", runs: [{ text: parts.join(SEPARATOR), mono: true }] };
}

/**
 * The collapsed strip: model, effort and usage. `null` means no data yet; `{}` means the
 * harness reports no usage. The context meter and cost live in the body only.
 */
export function buildSummary(usage: UsageSnapshot | null): SlotRoot {
  if (usage === null) return plain("—");
  if (Object.keys(usage).length === 0) return plain("No usage data");
  const nodes = [
    usage.model === undefined ? undefined : modelNode(usage.model, usage.effort),
    figuresNode(usage),
  ].filter((n): n is Text => n !== undefined);
  return nodes.length === 0 ? plain("—") : nodes;
}
