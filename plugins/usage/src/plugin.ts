import type { CallbackResult, JSONValue, SlotID } from "../../sdk/leo";
import type { CredentialKind, LeoV2, UsageRoot } from "./api";
import type { Clock } from "./clock";
import { createPoller } from "./poller";
import { CALLBACKS, fullRoot, sidebarRoot } from "./views";

export const SECTION_ID = "usage";
export const COMMANDS = {
  show: "show",
  addClaude: "add-claude",
  addCodex: "add-codex",
  refresh: "refresh",
} as const;

const KINDS: readonly CredentialKind[] = ["claude-code", "codex"];

const isObj = (v: unknown): v is { [key: string]: JSONValue } => typeof v === "object" && v !== null && !Array.isArray(v);
const asKind = (v: unknown): CredentialKind | null => KINDS.find((k) => k === v) ?? null;
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);

const note = (title: string, message?: string, sfSymbol?: string): UsageRoot => ({
  type: "EmptyState",
  title,
  ...(message !== undefined ? { message } : {}),
  ...(sfSymbol !== undefined ? { sfSymbol } : {}),
});

export function createPlugin(leo: LeoV2, clock: Clock): void {
  const sections = new Map<string, SlotID>();
  let showSlot: SlotID | null = null;
  let started: Promise<void> | null = null;

  const draw = (): void => {
    const accounts = poller.accounts();
    sections.forEach((slot) => leo.render(slot, sidebarRoot(accounts, clock.now())));
    if (showSlot) leo.render(showSlot, fullRoot(accounts, clock.now()));
  };

  const poller = createPoller(leo, clock, draw);

  const start = (): Promise<void> => {
    started = started ?? poller.start().catch((e: unknown) => {
      started = null; // a rejected start must not stick; the next activate or command retries
      throw e;
    });
    return started;
  };

  const safely =
    <A extends unknown[], R>(what: string, fn: (...args: A) => Promise<R>) =>
    async (...args: A): Promise<R | undefined> => {
      try {
        return await fn(...args);
      } catch (e) {
        leo.log("error", what + " failed: " + (e instanceof Error ? e.message : String(e)));
        return undefined;
      }
    };

  /** Gesture-only: `credentials.add` must be the first host call, before any await. */
  const addAccount = async (kind: CredentialKind, slot?: SlotID): Promise<void> => {
    const pending = leo.credentials.add(kind);
    const handle = await pending;
    if (slot?.kind === "palette") {
      leo.render(slot, handle ? note("Added " + handle.label, handle.path, "checkmark.circle.fill") : note("No account added", undefined, "xmark.circle"));
    }
    if (!handle) return;
    await poller.sync();
    await poller.refresh({ force: true });
  };

  /** Gesture-only, like add. */
  const authorize = async (id: string): Promise<void> => {
    const pending = leo.credentials.authorize(id);
    await pending;
    await poller.refresh({ force: true });
  };

  const activate = async (slot?: SlotID): Promise<void> => {
    if (slot?.kind === "section" && slot.id === SECTION_ID) sections.set(JSON.stringify(slot), slot);
    await start();
    draw();
  };

  const command = (id: string, slot?: SlotID): Promise<void> => {
    switch (id) {
      case COMMANDS.addClaude:
        return addAccount("claude-code", slot);
      case COMMANDS.addCodex:
        return addAccount("codex", slot);
      case COMMANDS.show:
        return showUsage(slot);
      case COMMANDS.refresh:
        return refreshNow(slot);
      default:
        return Promise.resolve();
    }
  };

  const showUsage = async (slot?: SlotID): Promise<void> => {
    if (slot?.kind === "palette") showSlot = slot;
    await start();
    draw();
  };

  const refreshNow = async (slot?: SlotID): Promise<void> => {
    await start();
    await poller.refresh({ force: true });
    if (slot?.kind === "palette") leo.render(slot, note("Usage refreshed", undefined, "checkmark.circle.fill"));
  };

  const callbackHandler = (id: string, payload: JSONValue): Promise<CallbackResult> => {
    const body = isObj(payload) ? payload : {};
    switch (id) {
      case CALLBACKS.add: {
        const kind = asKind(body.kind);
        return kind ? addAccount(kind).then(() => null) : Promise.resolve(null);
      }
      case CALLBACKS.authorize: {
        const target = str(body.id);
        return target ? authorize(target).then(() => null) : Promise.resolve(null);
      }
      case CALLBACKS.refresh:
        return refreshNow().then(() => null);
      case CALLBACKS.remove: {
        const target = str(body.id);
        return target ? removeAccount(target).then(() => null) : Promise.resolve(null);
      }
      case CALLBACKS.rename: {
        const inner = isObj(body.payload) ? body.payload : {};
        const target = str(inner.id);
        const values = isObj(body.values) ? body.values : {};
        const label = str(values.label);
        return target && label !== null ? poller.rename(target, label).then(() => null) : Promise.resolve(null);
      }
      default:
        return Promise.resolve(null);
    }
  };

  const removeAccount = async (id: string): Promise<void> => {
    await leo.credentials.remove(id);
    await poller.forget(id);
  };

  leo.on("activate", safely("activate", activate));
  leo.on("command", safely("command", command));
  leo.on("callback", safely("callback", callbackHandler));
}
