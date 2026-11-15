import type { Action, Node, SlotRoot } from "../../sdk/leo";
import type { RecordedRender } from "./stubLeo";

/** Mirrors LeoPluginNodeLimits and LeoPluginSymbolAllowlist. Returns every violation found in the tree. */
const MAX_DEPTH = 8;
const MAX_NODES = 2000;
const MAX_ACCESSORY_TEXT = 8;
const MAX_HELP = 80;
const MAX_ACTION_TITLE = 40;
const ACCESSORY_SYMBOLS: ReadonlySet<string> = new Set([
  "checkmark", "checkmark.circle", "checkmark.circle.fill", "xmark", "xmark.circle", "xmark.circle.fill",
  "exclamationmark.circle", "exclamationmark.circle.fill", "exclamationmark.triangle", "exclamationmark.triangle.fill",
  "questionmark.circle", "info.circle", "minus.circle", "plus.circle", "circle", "circle.fill", "circle.dotted",
  "clock", "clock.fill", "hourglass", "timer", "arrow.clockwise", "arrow.triangle.2.circlepath", "arrow.up", "arrow.down",
  "arrow.up.circle", "arrow.down.circle", "pause.circle", "play.circle", "stop.circle", "ellipsis", "ellipsis.circle",
  "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull", "point.3.connected.trianglepath.dotted",
  "chevron.left.forwardslash.chevron.right", "curlybraces", "terminal", "hammer", "wrench", "gearshape", "ladybug",
  "shippingbox", "tray", "doc", "doc.text", "folder", "link", "number", "tag", "flag", "flag.fill",
  "bell", "bell.fill", "bubble.left", "bubble.left.fill", "text.bubble", "person", "person.2", "star", "star.fill", "heart",
  "bolt", "bolt.fill", "lock", "lock.fill", "key", "eye", "eye.slash", "cloud", "network", "speedometer", "chart.bar",
]);

interface Walk {
  nodes: number;
  problems: string[];
}

const checkAccessory = (w: Walk, a: { text: string; help?: string; sfSymbol?: string }): void => {
  w.nodes += 1;
  if (a.text.length > MAX_ACCESSORY_TEXT) w.problems.push(`accessory text "${a.text}" over ${MAX_ACCESSORY_TEXT}`);
  if (a.help !== undefined && a.help.length > MAX_HELP) w.problems.push("accessory help over " + MAX_HELP);
  if (a.sfSymbol !== undefined && !ACCESSORY_SYMBOLS.has(a.sfSymbol)) w.problems.push(`accessory symbol ${a.sfSymbol} not allowed`);
};

const checkActions = (w: Walk, actions: readonly Action[] | undefined, depth: number): void => {
  for (const action of actions ?? []) {
    if (action.title !== undefined && action.title.length > MAX_ACTION_TITLE) w.problems.push(`action title "${action.title}" over ${MAX_ACTION_TITLE}`);
    if (action.type === "pushView") walkNode(w, action.node, depth + 1);
  }
};

function walkNode(w: Walk, node: Node, depth: number): void {
  w.nodes += 1;
  if (depth > MAX_DEPTH) w.problems.push("depth over " + MAX_DEPTH);
  switch (node.type) {
    case "Accessory":
      return checkAccessory(w, node);
    case "EmptyState":
      return checkActions(w, node.actions, depth);
    case "Error":
      return checkActions(w, [node.retry], depth);
    case "Form":
      w.nodes += node.fields.length;
      return node.fields.forEach((f) => checkActions(w, f.action ? [f.action] : [], depth));
    case "List": {
      const ids = node.sections.flatMap((s) => s.items.map((i) => i.id));
      if (new Set(ids).size !== ids.length) w.problems.push("duplicate list item ids");
      for (const item of node.sections.flatMap((s) => s.items)) {
        w.nodes += 1;
        (item.accessories ?? []).forEach((a) => checkAccessory(w, a));
        checkActions(w, item.actions, depth);
      }
      return;
    }
    default:
      return;
  }
}

export const limitProblems = (root: SlotRoot): string[] => {
  const w: Walk = { nodes: 0, problems: [] };
  (Array.isArray(root) ? root : [root]).forEach((n) => walkNode(w, n, 1));
  if (w.nodes > MAX_NODES) w.problems.push("over " + MAX_NODES + " nodes");
  return w.problems;
};

export const allLimitProblems = (renders: readonly RecordedRender[]): string[] => renders.flatMap((r) => limitProblems(r.tree));
