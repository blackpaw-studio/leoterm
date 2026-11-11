// Pure action constructors. They only build JSON; plugin code never performs
// a send or spawn itself. Leo gates every action (gesture, permission,
// confirmation sheet).
import type { Action, AgentRef, JSONValue, Node, SpawnSpec } from "./leo";

export const callback = (id: string, payload: JSONValue = null): Action => ({ type: "callback", id, payload });
export const pushView = (node: Node): Action => ({ type: "pushView", node });
/** https only; the host rejects other schemes. */
export const openURL = (url: string): Action => ({ type: "openURL", url });
export const copy = (text: string): Action => ({ type: "copy", text });
export const sendToAgent = (agent: AgentRef, text: string): Action => ({ type: "sendToAgent", agent, text });
export const spawnAgent = (spec: SpawnSpec): Action => ({ type: "spawnAgent", ...spec });
