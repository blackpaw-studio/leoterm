import type { Accessory, AccessoryColor, Action, Form } from "../../sdk/leo";
import type { CredentialKind, GroupNode, MeterNode, MeterTone, UsageNode, UsageRoot } from "./api";
import { MAX_HELP_CHARS, MAX_LINE_CHARS, clip, percentText, resetsIn, updatedAgo } from "./format";
import type { Account } from "./poller";
import { NO_DATA, type AccountState } from "./state";
import { highestWindow, toneFor, worstTone } from "./tone";
import type { UsageWindow } from "./window";

/** Callback ids the plugin handles. */
export const CALLBACKS = {
  refresh: "refresh",
  add: "add",
  authorize: "authorize",
  remove: "remove",
  rename: "rename",
} as const;

// Every symbol must be on the host allowlist (LeoPluginSymbolAllowlist.swift); test/symbols.test.ts enforces it.
const KIND_SYMBOL: Record<CredentialKind, string> = { "claude-code": "bubble.left.fill", codex: "terminal" };
const KIND_COMMAND: Record<CredentialKind, string> = { "claude-code": "claude", codex: "codex" };
const HEADER_SYMBOL = "speedometer";

const callback = (id: string, title: string, sfSymbol: string, payload?: Record<string, string>): Action => ({
  type: "callback",
  id,
  title,
  sfSymbol,
  ...(payload ? { payload } : {}),
});

const addActions: Action[] = [
  callback(CALLBACKS.add, "Add Claude Account…", "plus.circle", { kind: "claude-code" }),
  callback(CALLBACKS.add, "Add Codex Account…", "plus.circle", { kind: "codex" }),
];

const refreshAction = callback(CALLBACKS.refresh, "Refresh", "arrow.clockwise");

const accessory = (sfSymbol: string, text: string, color: AccessoryColor): Accessory => ({ type: "Accessory", sfSymbol, text, color });

const emptyState = (): UsageRoot => ({
  type: "EmptyState",
  title: "No accounts yet",
  message: "Add a Claude Code or Codex account to see its rate-limit usage.",
  sfSymbol: "plus.circle",
  actions: addActions,
});

const lowerFirst = (s: string): string => s.charAt(0).toLowerCase() + s.slice(1);

const meter = (w: UsageWindow, nowMs: number, detail?: string): MeterNode => ({
  type: "Meter",
  label: w.label,
  value: w.percent / 100,
  valueText: percentText(w.percent),
  ...(detail !== undefined ? { detail } : w.resetsAtMs !== undefined ? { detail: resetsIn(w.resetsAtMs, nowMs) } : {}),
  tone: toneFor(w.percent),
});

/** How the account's state shows in the title row, per the design's state table. */
const stateAccessory = (state: AccountState): Accessory | undefined => {
  switch (state.status) {
    case "stale":
      return { ...accessory("arrow.clockwise", "Stale", "warning"), ...(state.message !== undefined ? { help: clip(state.message, MAX_HELP_CHARS) } : {}) };
    case "expired":
      return accessory("xmark.circle", "Expired", "failure");
    case "needsAuthorization":
      return accessory("lock.fill", "Locked", "warning");
    case "error":
      return accessory("exclamationmark.triangle", "Error", "warning");
    default:
      return undefined;
  }
};

const stateText = (account: Account): string | undefined => {
  const { handle, state } = account;
  switch (state.status) {
    case "loading":
      return "Loading…";
    case "expired":
      return "Signed out — run `" + KIND_COMMAND[handle.kind] + "` with this account to refresh";
    case "needsAuthorization":
      return handle.kind === "claude-code"
        ? "Leo needs Keychain access to read this account"
        : "Leo needs access to read this account";
    case "error":
      return clip(state.message ?? NO_DATA, MAX_LINE_CHARS);
    default:
      return undefined;
  }
};

const signInCommand = (account: Account): string => {
  const { kind, path } = account.handle;
  return kind === "claude-code" ? "CLAUDE_CONFIG_DIR=" + path + " claude" : "CODEX_HOME=" + path + " codex login";
};

/** The state's own call to action leads (Return runs the first action); Refresh follows. */
const leadingActions = (account: Account): Action[] => {
  switch (account.state.status) {
    case "expired":
      return [{ type: "copy", title: "Copy Sign-in Command", sfSymbol: "doc", text: signInCommand(account) }];
    case "needsAuthorization":
      return [callback(CALLBACKS.authorize, "Grant Access…", "key", { id: account.handle.id })];
    default:
      return [];
  }
};

const staleDetail = (state: AccountState, nowMs: number): string | undefined =>
  state.status === "stale" && state.updatedAtMs !== undefined
    ? "Couldn't refresh · " + lowerFirst(updatedAgo(state.updatedAtMs, nowMs))
    : undefined;

const renameForm = (account: Account): Form => ({
  type: "Form",
  id: CALLBACKS.rename,
  title: "Rename Account",
  fields: [
    { id: "label", type: "text", label: "Name", value: account.label },
    {
      id: "submit",
      type: "submit",
      label: "Rename",
      action: { type: "callback", id: CALLBACKS.rename, payload: { id: account.handle.id } },
    },
  ],
});

const group = (account: Account, children: GroupNode["children"], subtitle: string | undefined, actions: Action[]): GroupNode => {
  const acc = stateAccessory(account.state);
  return {
    type: "Group",
    title: account.label,
    ...(subtitle !== undefined ? { subtitle } : {}),
    sfSymbol: KIND_SYMBOL[account.handle.kind],
    ...(acc ? { accessory: acc } : {}),
    children,
    actions,
  };
};

const sidebarGroup = (account: Account, nowMs: number): GroupNode => {
  const top = highestWindow(account.state.windows);
  const children = top ? [meter(top, nowMs, staleDetail(account.state, nowMs))] : [];
  const subtitle = children.length === 0 ? stateText(account) : undefined;
  return group(account, children, subtitle, [...leadingActions(account), refreshAction, ...addActions]);
};

const fullGroup = (account: Account, nowMs: number): GroupNode => {
  const { state, handle } = account;
  const updated = state.updatedAtMs !== undefined && state.windows.length > 0 ? updatedAgo(state.updatedAtMs, nowMs) : stateText(account);
  const subtitle = clip(updated === undefined ? handle.path : handle.path + " · " + updated, MAX_LINE_CHARS);
  const detail = staleDetail(state, nowMs);
  return group(
    account,
    state.windows.map((w) => meter(w, nowMs, detail)),
    subtitle,
    [
      ...leadingActions(account),
      refreshAction,
      { type: "pushView", title: "Rename…", sfSymbol: "tag", node: renameForm(account) },
      callback(CALLBACKS.remove, "Remove", "minus.circle", { id: handle.id }),
    ],
  );
};

const ACCESSORY_COLOR: Record<MeterTone, AccessoryColor> = {
  neutral: "neutral",
  success: "success",
  warning: "warning",
  failure: "failure",
};

/** The worst current meter across accounts, lifted by the host into the section header. */
const headerAccessory = (accounts: readonly Account[]): Accessory[] => {
  const tops = accounts.flatMap((a) => {
    const top = highestWindow(a.state.windows);
    return top ? [top] : [];
  });
  const worst = highestWindow(tops);
  if (!worst) return [];
  const tone = worstTone(tops.map((w) => toneFor(w.percent))) ?? "neutral";
  return [
    {
      type: "Accessory",
      sfSymbol: HEADER_SYMBOL,
      text: percentText(worst.percent),
      color: ACCESSORY_COLOR[tone],
      help: "Highest usage across accounts: " + worst.label,
    },
  ];
};

/** Sidebar section: header accessory first, then one compact Group per account. */
export function sidebarRoot(accounts: readonly Account[], nowMs: number): UsageRoot {
  if (accounts.length === 0) return emptyState();
  const nodes: UsageNode[] = [...headerAccessory(accounts), ...accounts.map((a) => sidebarGroup(a, nowMs))];
  return nodes;
}

/** "Show Account Usage": one Group per account with every window. */
export function fullRoot(accounts: readonly Account[], nowMs: number): UsageRoot {
  if (accounts.length === 0) return emptyState();
  return accounts.map((a) => fullGroup(a, nowMs));
}
