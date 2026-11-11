import type { Accessory, SlotRoot } from "../../../sdk/leo";
import type { CheckState } from "../pr/checks";

const MAX_TEXT = 8;
const SYMBOLS: Readonly<Record<CheckState, string>> = {
  success: "checkmark.circle.fill",
  failure: "xmark.circle.fill",
  running: "arrow.triangle.2.circlepath",
  neutral: "arrow.triangle.pull",
};

/** What a row's chip should show. `hidden`: unmapped agent or signed out. */
export type ChipModel =
  | { readonly kind: "pr"; readonly number: number; readonly state: CheckState }
  | { readonly kind: "noPr" }
  | { readonly kind: "hidden" };

const pad2 = (n: number): string => (n < 10 ? "0" + n : String(n));

/** Local-time HH:MM. */
export function formatResetTime(epochMs: number): string {
  const d = new Date(epochMs);
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
}

/** The accessory slot's render tree. `rateLimitedUntil` (epoch ms) keeps the chip and adds a help tooltip. */
export function accessoryRoot(model: ChipModel, rateLimitedUntil?: number | null): SlotRoot {
  if (model.kind === "hidden") return [];
  const chip: Accessory =
    model.kind === "noPr"
      ? { type: "Accessory", text: "no PR", color: "neutral" }
      : { type: "Accessory", text: ("#" + model.number).slice(0, MAX_TEXT), sfSymbol: SYMBOLS[model.state], color: model.state };
  return rateLimitedUntil == null ? chip : { ...chip, help: "Rate limited until " + formatResetTime(rateLimitedUntil) };
}
