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
// Limits: depth 8, 2000 nodes, unique list item ids, accessory text <= 8 chars,
// accessory help <= 80 chars.

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

export type Node = List | Detail | Form | Accessory | EmptyState | Loading | ErrorNode;
/** One component, or an ordered array drawn stacked. */
export type SlotRoot = Node | Node[];

// ---- Slots -----------------------------------------------------------------
// Opaque to plugin code: the app puts a slot in each event; hand it to leo.render.

export type SlotID =
  | { kind: "view"; viewID: string; agent: AgentRef }
  | { kind: "accessory"; id: string; agent: AgentRef }
  | { kind: "section"; id: string }
  | { kind: "palette"; commandID: string };

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
}

export interface TimerHandle { cancel(): void }

/** A callback may resolve to one follow-up action. It is dropped unless the callback began with a user gesture, and send/spawn still open the confirmation sheet. */
export type CallbackResult = Action | null | undefined | void;

export interface Events {
  activate: (slot?: SlotID) => void | Promise<void>;
  agentsChanged: () => void | Promise<void>;
  viewOpened: (agent: AgentRef, slot: SlotID) => void | Promise<void>;
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
  agents: { list(): Promise<AgentSnapshot[]> };
  /** Periodic; intervalSec >= 60. */
  timer(intervalSec: number, fn: () => void | Promise<void>): TimerHandle;
  /** One-shot; sec >= 1; runs only while one of the plugin's slots is visible. */
  after(sec: number, fn: () => void | Promise<void>): TimerHandle;
  log(level: string, message: string): void;
}

declare global {
  const leo: Leo;
}
