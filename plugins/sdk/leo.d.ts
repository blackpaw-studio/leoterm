// Leo plugin SDK types, API version 1. Mirrors LeoKit's Plugins module
// (LeoPluginNode, LeoPluginAction, LeoPluginBridge, the JS prelude) one to one.

export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

/** A top-level agent. `machine` is the host's display name. */
export interface AgentRef { machine: string; name: string }

export interface SpawnSpec {
  repo: string;
  branch: string;
  base?: string;
  prompt: string;
  machine?: string;
  /** Only preselects the sheet's Template picker; the user must leave one selected to confirm. */
  template?: string;
}

// ---- Actions ---------------------------------------------------------------

/** Optional label for menus and the ⌘↩ action panel. Without them Leo uses a default per action kind. */
export interface ActionLabel {
  /** At most 40 characters; longer is rejected. */
  title?: string;
  sfSymbol?: string;
}

export type Action = ActionLabel &
  (
    | { type: "callback"; id: string; payload?: JSONValue }
    | { type: "pushView"; node: Node }
    | { type: "openURL"; url: string }
    | { type: "copy"; text: string }
    | { type: "sendToAgent"; agent: AgentRef; text: string }
    | ({ type: "spawnAgent" } & SpawnSpec)
  );

// ---- Component tree --------------------------------------------------------
// Limits: depth 8, 2000 nodes (each Text and Meter counts as one node), unique
// list item ids, accessory text <= 8 chars, accessory help <= 80 chars, plus the
// Text and Meter limits documented on those types.

export type AccessoryColor = "neutral" | "success" | "warning" | "failure" | "running";

export interface Accessory {
  type: "Accessory";
  sfSymbol?: string;
  text: string;
  color?: AccessoryColor;
  help?: string;
}
/** An accessory as nested in a list item (no `type` tag on the wire). */
export type ItemAccessory = Omit<Accessory, "type">;

/**
 * Semantic colour token. The app maps each tone to a system dynamic colour, so it
 * follows light and dark mode. There are no raw hex values; anything outside this
 * set is rejected when the tree is decoded.
 */
export type Tone =
  | "secondary"
  | "accent1" | "accent2" | "accent3" | "accent4" | "accent5" | "accent6"
  | "success" | "warning" | "failure";

/** One styled span inside a `Text`. */
export interface TextRun {
  /** At most 200 characters; longer is rejected. */
  text: string;
  /** Omitted means the default label colour. */
  tone?: Tone;
  /** Omitted means "regular". */
  weight?: "regular" | "semibold";
  /** Monospaced digits and glyphs. Omitted means false. */
  mono?: boolean;
}

/**
 * An inline row of styled runs, drawn left to right on one line (truncated at the
 * tail when too wide). At most 20 runs, and at least 1. Allowed in every slot,
 * including a pane summary.
 */
export interface Text { type: "Text"; runs: TextRun[] }

/** One filled portion of a `Meter`. */
export interface MeterSegment {
  /** Finite and >= 0, in the same unit as the meter's `max`. */
  value: number;
  tone: Tone;
}

/**
 * A horizontal bar made of segments drawn left to right. Allowed in every slot,
 * including a pane summary (drawn 56pt x 5pt; in a pane body it fills the width).
 * Limits: 1 to 8 segments; `max` finite and > 0; every `value` finite and >= 0.
 * Segments that sum past `max` are clamped to the bar, not rejected.
 */
export interface Meter {
  type: "Meter";
  segments: MeterSegment[];
  max: number;
  /** Short text next to the bar (for example "62%"). At most 40 characters. */
  label?: string;
  /** Tooltip text. At most 80 characters; longer is rejected. */
  help?: string;
}

export interface ListItem {
  id: string;
  title: string;
  subtitle?: string;
  sfSymbol?: string;
  accessories?: ItemAccessory[];
  /** Shown in the context menu and the ⌘↩ panel; the first runs on Return. */
  actions?: Action[];
}
export interface ListSection { id?: string; title?: string; items: ListItem[] }
export interface List { type: "List"; sections: ListSection[] }

/** Restricted Markdown: headings, emphasis, code, links, lists. Size is capped by the host. */
export interface Detail { type: "Detail"; markdown: string }

export interface FieldOption { value: string; title: string }
export interface Field {
  id: string;
  type: "text" | "textArea" | "picker" | "checkbox" | "submit";
  label?: string;
  placeholder?: string;
  value?: string;
  checked?: boolean;
  /** Required (non-empty) for `picker`. */
  options?: FieldOption[];
  action?: Action;
}
export interface Form { type: "Form"; id: string; title?: string; fields: Field[] }

export interface EmptyState { type: "EmptyState"; title: string; message?: string; sfSymbol?: string; actions?: Action[] }
export interface Loading { type: "Loading"; message?: string }
export interface ErrorNode { type: "Error"; message: string; retry: Action }

export type Node = List | Detail | Form | Accessory | Text | Meter | EmptyState | Loading | ErrorNode;
/** One component, or an ordered array drawn stacked. */
export type SlotRoot = Node | Node[];

// ---- Slots -----------------------------------------------------------------
// Opaque to plugin code: the app puts a slot in each event; hand it to leo.render.

export type SlotID =
  | { kind: "view"; viewID: string; agent: AgentRef }
  | { kind: "accessory"; id: string; agent: AgentRef }
  | { kind: "section"; id: string }
  | { kind: "palette"; commandID: string }
  | PaneSlot;

/**
 * A slot under one agent's terminal/chat view, contributed through the manifest's
 * `contributes.panes` (at most one pane per plugin). The app sends it as the
 * second argument of `viewOpened(agent, slot)` once for each part when that agent
 * is selected; render into it with `leo.render(slot, tree)`. Slots are per agent.
 *
 * - `summary`: the one-line strip shown in the collapsed tab bar. Only `Text`,
 *   `Meter` and `Accessory` (as one `Node` or an array of them) are accepted,
 *   laid out in a single row. Anything else puts the slot in an error state,
 *   drawn as "!" with the reason in a tooltip.
 * - `body`: the expanded drawer. Accepts every component. It is visible only
 *   while the plugin's tab is expanded.
 */
export interface PaneSlot {
  kind: "pane";
  /** The `id` of the manifest pane entry. */
  id: string;
  part: "summary" | "body";
  agent: AgentRef;
}

// ---- Bridge ----------------------------------------------------------------

export interface FetchInit {
  method?: string;
  headers?: Record<string, string>;
  /** Strings only. */
  body?: string;
}
export interface FetchResponse {
  status: number;
  headers: Record<string, string>;
  /** UTF-8 text, or base64 when the bytes are not valid UTF-8. */
  body: string;
  bodyEncoding: "utf8" | "base64";
}

export interface AgentSnapshot {
  name: string;
  machine: string;
  status: string;
  repo: string | null;
  branch: string | null;
  hasWorktree: boolean;
  /**
   * The agent's working directory, home-relative (`~/.leo/agents/leoterm`), or
   * absolute when it is outside the home directory. Present only when the plugin
   * holds `agents: ["usage"]`; omitted otherwise (and when unknown). The plugin
   * shortens it itself.
   */
  workspace?: string;
  /**
   * The model: the observed one when the daemon reports it, else the configured
   * one. Present only with `agents: ["usage"]`; omitted otherwise or when unknown.
   */
  model?: string;
}

/** A named usage meter from the harness, such as a rate limit window. */
export interface RateLimit {
  /** Window kind. Unknown kinds are passed through as sent. */
  kind: "five_hour" | "seven_day" | (string & {});
  /** Percent of the window used, 0 to 100 (may exceed 100 briefly). */
  percentUsed: number;
  /** When the window resets, ISO 8601 UTC (for example "2026-11-12T05:00:00Z"). */
  resetsAt: string;
}

/**
 * The latest usage data for one agent. Every key is optional: absent keys are
 * omitted from the object (never null, never zero-filled), so check for
 * presence. Unknown daemon fields are dropped.
 */
export interface UsageSnapshot {
  /** Observed model when the daemon reports it, otherwise the configured one. */
  model?: string;
  /** Reasoning effort, such as "low", "medium", "high". Passed through as sent. */
  effort?: string;
  context?: {
    /** Tokens currently in the context window. */
    tokens: number;
    /** Size of the context window in tokens. */
    window: number;
    /** `tokens / window` as a percentage, 0 to 100. */
    percent: number;
    /** Token split by source. Each key is optional. */
    breakdown?: { system?: number; tools?: number; mcp?: number; memory?: number; messages?: number };
    /** The fraction of the window (0 to 1) at which the harness auto-compacts. */
    compactAt?: number;
  };
  session?: {
    /** Tokens used this session. */
    tokens: number;
    /** Estimated cost in US dollars. */
    costUsd: number;
  };
  rateLimits?: RateLimit[];
  /** Lines changed in the agent's working tree. */
  git?: { added: number; removed: number };
}

export interface TimerHandle { cancel(): void }

/** A callback may resolve to one follow-up action. It is dropped unless the callback began with a user gesture, and send/spawn still open the confirmation sheet. */
export type CallbackResult = Action | null | undefined | void;

export interface Events {
  activate: (slot?: SlotID) => void | Promise<void>;
  agentsChanged: () => void | Promise<void>;
  /**
   * A view, accessory or pane slot opened for `agent`. For a pane the slot is a
   * `PaneSlot`; the event fires once per part (`summary`, `body`) when the agent
   * is selected, and again if the slot is re-created.
   */
  viewOpened: (agent: AgentRef, slot: SlotID) => void | Promise<void>;
  /**
   * An agent's usage data changed (the daemon's agent_usage or agent_turn_completed).
   * Needs `agents: ["usage"]`. Coalesced to at most one per agent per second, and
   * delivered only while one of the plugin's panes is visible. Call
   * `leo.agents.usage(agent)` to read the new data.
   */
  usageChanged: (agent: AgentRef) => void | Promise<void>;
  command: (id: string, slot?: SlotID) => void | Promise<void>;
  callback: (id: string, payload: JSONValue) => CallbackResult | Promise<CallbackResult>;
}

export interface Leo {
  render(slot: SlotID, tree: SlotRoot): void;
  on<E extends keyof Events>(event: E, fn: Events[E]): void;
  /** Rejects when the host is not in the manifest, on rate limit (60/min, 4 in flight) or a body over 5 MB. */
  fetch(url: string, init?: FetchInit): Promise<FetchResponse>;
  secrets: {
    get(key: string): Promise<string | null>;
    /** Resolves to null. */
    set(key: string, value: string): Promise<null>;
    /** Resolves to null, whether or not the key existed. */
    delete(key: string): Promise<null>;
  };
  agents: {
    list(): Promise<AgentSnapshot[]>;
    /**
     * The latest usage snapshot for an agent. Needs `agents: ["usage"]`; rejects
     * with "permission denied" otherwise.
     * - `null`: no data yet (the agent has not reported); try again after `usageChanged`.
     * - `{}`: the agent's harness does not report usage; do not wait for data.
     */
    usage(agent: AgentRef): Promise<UsageSnapshot | null>;
  };
  /** Periodic; intervalSec >= 60. */
  timer(intervalSec: number, fn: () => void | Promise<void>): TimerHandle;
  /** One-shot; sec >= 1; runs only while one of the plugin's slots is visible. */
  after(sec: number, fn: () => void | Promise<void>): TimerHandle;
  log(level: string, message: string): void;
}

declare global {
  const leo: Leo;
}
