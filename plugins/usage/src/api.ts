/**
 * API v2 additions the usage plugin codes against (spec: docs/superpowers/specs/2026-11-21-usage-plugin.md).
 * Kept local so this package does not depend on the shared SDK typings catching up.
 */
import type { Accessory, Action, Events, FetchInit, FetchResponse, Leo, Node, SlotID } from "../../sdk/leo";

export type CredentialKind = "claude-code" | "codex";

/** A user-granted account. `id` is opaque; `path` is for display only. */
export interface Handle {
  id: string;
  kind: CredentialKind;
  label: string;
  path: string;
}

export type CredentialFailureReason = "credentialNeedsAuthorization" | "credentialHostMismatch" | "gestureRequired";

export type MeterTone = "neutral" | "success" | "warning" | "failure";

export interface MeterNode {
  type: "Meter";
  label: string;
  /** 0…1, clamped by the host. */
  value: number;
  valueText?: string;
  detail?: string;
  tone: MeterTone;
}

export interface GroupNode {
  type: "Group";
  title: string;
  subtitle?: string;
  sfSymbol?: string;
  accessory?: Omit<Accessory, "type"> & { type: "Accessory" };
  children: Array<MeterNode | Accessory>;
  actions?: Action[];
}

export type UsageNode = GroupNode | MeterNode | Node;
export type UsageRoot = UsageNode | UsageNode[];

export interface Credentials {
  /** Gesture-only: call synchronously inside a callback or command handler, before any await. */
  add(kind: CredentialKind): Promise<Handle | null>;
  /** Gesture-only. */
  authorize(id: string): Promise<null>;
  list(): Promise<Handle[]>;
  remove(id: string): Promise<null>;
}

export type UsageFetchInit = FetchInit & { credential?: string };

/** v2 adds `credentialsChanged`: this plugin's grant set changed (including removal from Settings). No payload. */
export type EventsV2 = Events & { credentialsChanged: () => void | Promise<void> };

export type LeoV2 = Omit<Leo, "fetch" | "render" | "on"> & {
  on<E extends keyof EventsV2>(event: E, fn: EventsV2[E]): void;
  fetch(url: string, init?: UsageFetchInit): Promise<FetchResponse>;
  render(slot: SlotID, tree: UsageRoot): void;
  credentials: Credentials;
};
