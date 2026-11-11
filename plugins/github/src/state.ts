import type { AgentRef, AgentSnapshot, SlotID } from "../../sdk/leo";
import type { CheckItem } from "./pr/checks";
import type { PullRequest } from "./pr/match";

/** What the poll knows about one agent's branch. */
export type PrStatus =
  | { readonly kind: "unmapped" }
  | { readonly kind: "noPr" }
  | { readonly kind: "pr"; readonly pr: PullRequest; readonly checks: readonly CheckItem[] };

export interface SlotEntry {
  readonly slot: SlotID;
  /** `machine/name`, or null for slots that aren't about one agent. */
  readonly agentKey: string | null;
}

export interface State {
  readonly agents: ReadonlyMap<string, AgentSnapshot>;
  readonly statuses: ReadonlyMap<string, PrStatus>;
  /** Keyed by the slot's JSON form. */
  readonly slots: ReadonlyMap<string, SlotEntry>;
}

export const initialState: State = { agents: new Map(), statuses: new Map(), slots: new Map() };

export const agentKey = (a: AgentRef): string => a.machine + "/" + a.name;
export const slotKey = (s: SlotID): string => JSON.stringify(s);

const withEntry = <V>(map: ReadonlyMap<string, V>, key: string, value: V): Map<string, V> => new Map(map).set(key, value);

export const withSlot = (state: State, slot: SlotID, key: string | null): State => ({
  ...state,
  slots: withEntry(state.slots, slotKey(slot), { slot, agentKey: key }),
});

export const withStatus = (state: State, key: string, status: PrStatus): State => ({
  ...state,
  statuses: withEntry(state.statuses, key, status),
});

export const withoutStatuses = (state: State): State => ({ ...state, statuses: new Map() });

export interface AgentDiff {
  readonly state: State;
  /** Keys that are new or whose repo/branch changed. */
  readonly changed: readonly string[];
}

const sameBranch = (a: AgentSnapshot, b: AgentSnapshot): boolean => a.repo === b.repo && a.branch === b.branch;

/** Replace the agent list. Agents that left lose their status and slots; changed ones lose their status. */
export function withAgents(state: State, list: readonly AgentSnapshot[]): AgentDiff {
  const next = new Map(list.map((a) => [agentKey(a), a] as const));
  const changed = [...next].filter(([k, a]) => {
    const prev = state.agents.get(k);
    return prev === undefined || !sameBranch(prev, a);
  }).map(([k]) => k);
  const gone = (k: string | null): boolean => k !== null && !next.has(k);
  const statuses = new Map([...state.statuses].filter(([k]) => next.has(k) && !changed.includes(k)));
  const slots = new Map([...state.slots].filter(([, e]) => !gone(e.agentKey)));
  return { state: { agents: next, statuses, slots }, changed };
}

export const slotsOfKind = (state: State, kind: SlotID["kind"]): SlotEntry[] =>
  [...state.slots.values()].filter((e) => e.slot.kind === kind);

export const slotsForAgent = (state: State, key: string, kind: SlotID["kind"]): SlotEntry[] =>
  slotsOfKind(state, kind).filter((e) => e.agentKey === key);
