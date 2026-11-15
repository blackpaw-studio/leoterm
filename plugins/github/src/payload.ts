import type { AgentRef, SlotID } from "../../sdk/leo";

/** Narrowing helpers for callback payloads, which arrive as untrusted JSON. */
export const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
export const isStr = (v: unknown): v is string => typeof v === "string";

export const parseAgentRef = (v: unknown): AgentRef | null =>
  isObj(v) && isStr(v.machine) && isStr(v.name) ? { machine: v.machine, name: v.name } : null;

export const parseSlot = (v: unknown): SlotID | null => (isObj(v) && isStr(v.kind) ? (v as unknown as SlotID) : null);
