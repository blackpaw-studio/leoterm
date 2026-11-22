import type { CredentialKind, Handle, LeoV2 } from "./api";
import type { Clock } from "./clock";
import { parseClaude } from "./parse/claude";
import { parseCodex } from "./parse/codex";
import { initialState, isDue, reduce, type AccountState, type Outcome } from "./state";
import { loadPersisted, savePersisted, type Persisted } from "./store";
import type { UsageWindow } from "./window";

export const CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage";
export const CODEX_URL = "https://chatgpt.com/backend-api/wham/usage";
export const POLL_INTERVAL_SEC = 300;

interface Provider {
  url: string;
  parse(body: unknown): UsageWindow[];
}

const PROVIDERS: Record<CredentialKind, Provider> = {
  "claude-code": { url: CLAUDE_URL, parse: parseClaude },
  codex: { url: CODEX_URL, parse: parseCodex },
};

export interface Account {
  handle: Handle;
  /** The user's custom name, else the host's label. */
  label: string;
  state: AccountState;
}

export interface RefreshOptions {
  /** Manual refresh: ignore 429 backoff. */
  force?: boolean;
}

export interface Poller {
  /** Reconcile with `credentials.list()` and restore persisted state. */
  sync(): Promise<void>;
  /** Refresh every due account, one request at a time. Concurrent calls share one pass. */
  refresh(options?: RefreshOptions): Promise<void>;
  /** sync + refresh now, then every 5 minutes. */
  start(): Promise<void>;
  accounts(): readonly Account[];
  rename(id: string, label: string): Promise<void>;
  /** Forget an account locally after its grant was removed. */
  forget(id: string): Promise<void>;
}

const errorMessage = (e: unknown): string => (e instanceof Error ? e.message : String(e));

async function fetchOutcome(leo: LeoV2, handle: Handle): Promise<Outcome> {
  const provider = PROVIDERS[handle.kind];
  try {
    const res = await leo.fetch(provider.url, { credential: handle.id, headers: { Accept: "application/json" } });
    if (res.status === 401) return { kind: "unauthorized" };
    if (res.status === 429) return { kind: "rateLimited" };
    if (res.status !== 200) return { kind: "failed", message: "HTTP " + res.status };
    try {
      return { kind: "ok", windows: provider.parse(JSON.parse(res.body)) };
    } catch {
      return { kind: "failed", message: "Unreadable response" };
    }
  } catch (e) {
    const message = errorMessage(e);
    return message.includes("credentialNeedsAuthorization") ? { kind: "needsAuthorization" } : { kind: "failed", message };
  }
}

export function createPoller(leo: LeoV2, clock: Clock, onChange: () => void): Poller {
  let entries: Array<{ handle: Handle; state: AccountState }> = [];
  let persisted: Persisted | null = null;
  let inFlight: Promise<void> | null = null;

  const persist = async (): Promise<void> => {
    const base = persisted ?? (await loadPersisted(leo));
    persisted = {
      order: entries.map((e) => e.handle.id),
      labels: Object.fromEntries(Object.entries(base.labels).filter(([id]) => entries.some((e) => e.handle.id === id))),
      snapshots: Object.fromEntries(
        entries.flatMap((e) =>
          e.state.windows.length > 0 && e.state.updatedAtMs !== undefined
            ? [[e.handle.id, { windows: [...e.state.windows], updatedAtMs: e.state.updatedAtMs }] as const]
            : [],
        ),
      ),
    };
    await savePersisted(leo, persisted);
  };

  const setState = (id: string, state: AccountState): void => {
    entries = entries.map((e) => (e.handle.id === id ? { ...e, state } : e));
    onChange();
  };

  const restore = (handle: Handle, saved: Persisted): AccountState => {
    const snap = saved.snapshots[handle.id];
    return snap ? { status: "ok", windows: snap.windows, updatedAtMs: snap.updatedAtMs } : initialState();
  };

  const sync = async (): Promise<void> => {
    persisted = persisted ?? (await loadPersisted(leo));
    const saved = persisted;
    const handles = await leo.credentials.list();
    const rank = (h: Handle): number => {
      const i = saved.order.indexOf(h.id);
      return i === -1 ? Number.MAX_SAFE_INTEGER : i;
    };
    const ordered = handles.map((h, i) => ({ h, i })).sort((a, b) => rank(a.h) - rank(b.h) || a.i - b.i).map((x) => x.h);
    entries = ordered.map((handle) => ({
      handle,
      state: entries.find((e) => e.handle.id === handle.id)?.state ?? restore(handle, saved),
    }));
    if (JSON.stringify(entries.map((e) => e.handle.id)) !== JSON.stringify(saved.order)) await persist();
    onChange();
  };

  const pass = async (options: RefreshOptions): Promise<void> => {
    for (const { handle } of [...entries]) {
      const current = entries.find((e) => e.handle.id === handle.id);
      if (!current || (!options.force && !isDue(current.state, clock.now()))) continue;
      const outcome = await fetchOutcome(leo, handle);
      if (entries.some((e) => e.handle.id === handle.id)) {
        setState(handle.id, reduce(entries.find((e) => e.handle.id === handle.id)?.state ?? initialState(), outcome, clock.now()));
      }
    }
    await persist();
  };

  const refresh = (options: RefreshOptions = {}): Promise<void> => {
    if (inFlight) return inFlight;
    inFlight = pass(options).finally(() => {
      inFlight = null;
    });
    return inFlight;
  };

  return {
    sync,
    refresh,
    start: async () => {
      await sync();
      await refresh();
      leo.timer(POLL_INTERVAL_SEC, async () => {
        await sync();
        await refresh();
      });
    },
    accounts: () =>
      entries.map((e) => ({ handle: e.handle, label: persisted?.labels[e.handle.id] ?? e.handle.label, state: e.state })),
    rename: async (id, label) => {
      const base = persisted ?? (await loadPersisted(leo));
      const trimmed = label.trim();
      const { [id]: _dropped, ...rest } = base.labels;
      persisted = { ...base, labels: trimmed === "" ? rest : { ...rest, [id]: trimmed } };
      await savePersisted(leo, persisted);
      onChange();
    },
    forget: async (id) => {
      entries = entries.filter((e) => e.handle.id !== id);
      await persist();
      onChange();
    },
  };
}
