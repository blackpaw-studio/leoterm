import type { LeoV2 } from "./api";
import { finiteNumber, isRecord, type UsageWindow } from "./window";

/** Last good reading of one account. */
export interface Snapshot {
  windows: UsageWindow[];
  updatedAtMs: number;
}

/** Everything the plugin persists. Never tokens: the host keeps those. */
export interface Persisted {
  order: string[];
  labels: Record<string, string>;
  snapshots: Record<string, Snapshot>;
}

export const STATE_KEY = "state";
/** The host caps a secret value at 16 KB; stay under it with room for multi-byte labels. */
export const MAX_STATE_CHARS = 15_000;
const MAX_LABEL_CHARS = 60;

export const emptyPersisted = (): Persisted => ({ order: [], labels: {}, snapshots: {} });

const WINDOW_KEYS: ReadonlySet<string> = new Set(["session", "weekly", "weekly-opus", "weekly-sonnet"]);

const readWindow = (v: unknown): UsageWindow[] => {
  if (!isRecord(v) || typeof v.key !== "string" || !WINDOW_KEYS.has(v.key) || typeof v.label !== "string") return [];
  const percent = finiteNumber(v.percent);
  if (percent === undefined) return [];
  const resetsAtMs = finiteNumber(v.resetsAtMs);
  const base = { key: v.key as UsageWindow["key"], label: v.label, percent };
  return [resetsAtMs === undefined ? base : { ...base, resetsAtMs }];
};

const readSnapshot = (v: unknown): Snapshot[] => {
  if (!isRecord(v) || !Array.isArray(v.windows)) return [];
  const updatedAtMs = finiteNumber(v.updatedAtMs);
  return updatedAtMs === undefined ? [] : [{ windows: v.windows.flatMap(readWindow), updatedAtMs }];
};

/** Keeps only well-formed entries; the stored value may come from an older or damaged version. */
export function sanitize(raw: unknown): Persisted {
  if (!isRecord(raw)) return emptyPersisted();
  const order = Array.isArray(raw.order) ? raw.order.filter((id): id is string => typeof id === "string") : [];
  const labels = isRecord(raw.labels)
    ? Object.fromEntries(
        Object.entries(raw.labels)
          .filter((e): e is [string, string] => typeof e[1] === "string")
          .map(([id, label]) => [id, label.slice(0, MAX_LABEL_CHARS)]),
      )
    : {};
  const snapshots = isRecord(raw.snapshots)
    ? Object.fromEntries(Object.entries(raw.snapshots).flatMap(([id, s]) => readSnapshot(s).map((snap) => [id, snap] as const)))
    : {};
  return { order, labels, snapshots };
}

export async function loadPersisted(leo: Pick<LeoV2, "secrets">): Promise<Persisted> {
  const raw = await leo.secrets.get(STATE_KEY);
  if (raw === null) return emptyPersisted();
  try {
    return sanitize(JSON.parse(raw));
  } catch {
    return emptyPersisted();
  }
}

/** Drops the oldest snapshots until the JSON fits; order and labels always survive. */
export function fit(state: Persisted): Persisted {
  const byAge = Object.entries(state.snapshots).sort((a, b) => a[1].updatedAtMs - b[1].updatedAtMs);
  const trimmed = (dropped: number): Persisted => ({ ...state, snapshots: Object.fromEntries(byAge.slice(dropped)) });
  for (let dropped = 0; dropped <= byAge.length; dropped += 1) {
    const candidate = trimmed(dropped);
    if (JSON.stringify(candidate).length <= MAX_STATE_CHARS) return candidate;
  }
  return trimmed(byAge.length);
}

export async function savePersisted(leo: Pick<LeoV2, "secrets">, state: Persisted): Promise<void> {
  await leo.secrets.set(STATE_KEY, JSON.stringify(fit(sanitize(state))));
}
