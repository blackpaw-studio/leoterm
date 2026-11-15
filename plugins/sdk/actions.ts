// Pure action constructors. They only build JSON; plugin code never performs
// a send or spawn itself. Leo gates every action (gesture, permission,
// confirmation sheet).
import type { Action, ActionLabel, AgentRef, JSONValue, Node, SpawnSpec } from "./leo";

// Every constructor takes an optional trailing `label` ({ title?, sfSymbol? }) for menus and the action panel.
export const callback = (id: string, payload: JSONValue = null, label: ActionLabel = {}): Action => ({ type: "callback", id, payload, ...label });
export const pushView = (node: Node, label: ActionLabel = {}): Action => ({ type: "pushView", node, ...label });
/** https only; the host rejects other schemes. */
export const openURL = (url: string, label: ActionLabel = {}): Action => ({ type: "openURL", url, ...label });
export const copy = (text: string, label: ActionLabel = {}): Action => ({ type: "copy", text, ...label });
export const sendToAgent = (agent: AgentRef, text: string, label: ActionLabel = {}): Action => ({ type: "sendToAgent", agent, text, ...label });
/** `spec.template` only preselects the confirmation sheet's Template picker. */
export const spawnAgent = (spec: SpawnSpec, label: ActionLabel = {}): Action => ({ type: "spawnAgent", ...spec, ...label });
