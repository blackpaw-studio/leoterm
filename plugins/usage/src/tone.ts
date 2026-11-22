import type { MeterTone } from "./api";
import type { UsageWindow } from "./window";

const WARNING_AT = 75;
const FAILURE_AT = 90;

export const toneFor = (percent: number): MeterTone => (percent >= FAILURE_AT ? "failure" : percent >= WARNING_AT ? "warning" : "success");

const RANK: Record<MeterTone, number> = { neutral: 0, success: 1, warning: 2, failure: 3 };

export const worstTone = (tones: readonly MeterTone[]): MeterTone | undefined =>
  tones.reduce<MeterTone | undefined>((worst, t) => (worst === undefined || RANK[t] > RANK[worst] ? t : worst), undefined);

/** First window wins ties, so Session stays ahead of an equal Weekly. */
export const highestWindow = (windows: readonly UsageWindow[]): UsageWindow | undefined =>
  windows.reduce<UsageWindow | undefined>((best, w) => (best === undefined || w.percent > best.percent ? w : best), undefined);
