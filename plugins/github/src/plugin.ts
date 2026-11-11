import type { AgentRef, Leo, SlotID, SlotRoot, TimerHandle } from "../../sdk/leo";
import { createSession } from "./auth/session";
import { runCallback } from "./callbacks";
import type { Clock } from "./clock";
import { issuesRoot, renderIssues, runCommand } from "./commands";
import { COMMANDS, VIEW_ID } from "./config";
import type { Ctx } from "./context";
import { createGitHubClient, type ApiResponse, type GitHubClient } from "./github/client";
import { createEtagCache } from "./github/etagCache";
import { describeError } from "./github/describe";
import type { GitHubError, Result } from "./github/errors";
import { observeClient } from "./github/observed";
import { fetchAssignedIssues } from "./issues/list";
import { combineState } from "./pr/checks";
import { fetchPrStatus, mappedOf } from "./prStatus";
import { fetchReviewThreads, type ReviewState } from "./reviews/threads";
import { createScheduler, POLL_REQUESTS_PER_STATUS, type Scheduler } from "./scheduler";
import {
  agentKey,
  initialState,
  slotsForAgent,
  slotsOfKind,
  slotKey,
  withAgents,
  withoutStatuses,
  withSlot,
  withFailure,
  withStatus,
  type PrStatus,
  type State,
} from "./state";
import { accessoryRoot, type ChipModel } from "./ui/accessory";
import { retryCommandAction, viewRoot } from "./ui/view";

const POLL_INTERVAL_SEC = 60;

/**
 * A good refresh replaces the status. An HTTP error marks the chip as failed instead of leaving the old
 * status looking current. Unauthorized (the session signs out), rate limits (the pause shows) and
 * transport failures (offline, host limit) keep what's there.
 */
const recordRefresh = (state: State, key: string, res: Result<PrStatus>): State => {
  if (res.ok) return withStatus(state, key, res.value);
  return res.error.kind === "Http" ? withFailure(state, key, describeError(res.error)) : state;
};
const ISSUES_KEY = "issues";

/** Composition root. Everything below takes `leo` and `clock` as parameters. */
export function createPlugin(leo: Leo, clock: Clock): void {
  const scheduler = createScheduler(clock);
  const etags = createEtagCache<ApiResponse>();
  /** A client whose every `leo.fetch` passes the scheduler's gate for `lane`; the lanes share one ETag cache. */
  const clientOn = (gate: Scheduler["user"]): GitHubClient =>
    createGitHubClient({ fetch: (url, init) => gate(() => leo.fetch(url, init)) }, clock, etags);
  const rawClient = clientOn(scheduler.user);
  const session = createSession({ leo, clock, client: rawClient, run: scheduler.user });
  const observe = async (error: GitHubError, auth: string | null): Promise<void> => {
    if (error.kind === "Unauthorized") await session.handleError(error, auth);
    else if (error.kind === "RateLimited") {
      scheduler.pauseUntil(error.resetAt);
      drawAccessories();
    }
  };
  /** User lane: view open, actions, sign-in. */
  const client = observeClient(rawClient, observe);
  /** Poll lane: capped at 40 of Leo's 60 requests a minute. */
  const pollClient = observeClient(clientOn(scheduler.poll), observe);

  let state: State = initialState;
  let timer: TimerHandle | null = null;
  let loaded: Promise<void> | null = null;
  /** Last tree drawn into each poll-driven slot, so a 304 cycle doesn't re-render. */
  let drawn = new Map<string, string>();

  const ready = (): Promise<void> => (loaded ??= session.load());

  const draw = (slot: SlotID, root: SlotRoot): void => {
    const json = JSON.stringify(root);
    if (drawn.get(slotKey(slot)) === json) return;
    drawn = new Map(drawn).set(slotKey(slot), json);
    leo.render(slot, root);
  };

  const register = (slot: SlotID, key: string | null): void => {
    state = withSlot(state, slot, key);
    session.track(slot);
  };

  // ---- Accessories ----------------------------------------------------------

  const chipOf = (key: string): ChipModel => {
    const failure = state.failures.get(key);
    if (failure !== undefined) return { kind: "error", reason: failure };
    const status = state.statuses.get(key);
    if (status === undefined || status.kind === "unmapped") return { kind: "hidden" };
    return status.kind === "noPr" ? { kind: "noPr" } : { kind: "pr", number: status.pr.number, state: combineState(status.checks) };
  };

  function drawAccessories(keys?: readonly string[]): void {
    const until = scheduler.pausedUntil();
    for (const entry of slotsOfKind(state, "accessory")) {
      if (entry.agentKey !== null && (keys === undefined || keys.includes(entry.agentKey))) {
        draw(entry.slot, accessoryRoot(chipOf(entry.agentKey), until));
      }
    }
  }

  // ---- Agents ---------------------------------------------------------------

  /** Reload the agent list; drops slots and statuses of agents that left. Returns the new or changed keys. */
  async function syncAgents(): Promise<readonly string[]> {
    const diff = withAgents(state, await leo.agents.list());
    state = diff.state;
    return diff.changed;
  }

  async function refreshAgent(key: string): Promise<void> {
    const auth = session.token();
    const agent = state.agents.get(key);
    if (auth === null || agent === undefined) return;
    const res = await fetchPrStatus(client, auth, agent);
    if (session.token() === auth) state = recordRefresh(state, key, res);
    if (session.token() === auth) drawAccessories([key]);
  }

  const hasSlots = (key: string): boolean => slotsForAgent(state, key, "accessory").length + slotsForAgent(state, key, "view").length > 0;

  async function onAgentsChanged(): Promise<void> {
    await ready();
    const changed = (await syncAgents()).filter(hasSlots);
    await Promise.all(changed.map(refreshAgent));
  }

  // ---- Polling --------------------------------------------------------------

  async function pollIssues(auth: string): Promise<void> {
    const sections = slotsOfKind(state, "section");
    if (sections.length === 0) return;
    const cycle = await scheduler.pollCycle([ISSUES_KEY], () => fetchAssignedIssues(pollClient, auth));
    const res = cycle.results.get(ISSUES_KEY);
    if (!res?.ok || session.token() !== auth) return;
    const root = issuesRoot(res.value, await leo.agents.list());
    sections.forEach((s) => draw(s.slot, root));
  }

  async function poll(): Promise<void> {
    const auth = session.token();
    if (auth === null || scheduler.pausedUntil() !== null) return;
    await syncAgents();
    const keys = [...state.agents.keys()].filter((k) => hasSlots(k) && mappedOf(state.agents.get(k)!) !== null);
    const cycle = await scheduler.pollCycle(keys, (key) => fetchPrStatus(pollClient, auth, state.agents.get(key)!), {
      cost: POLL_REQUESTS_PER_STATUS,
    });
    if (session.token() !== auth) return;
    cycle.results.forEach((res, key) => {
      state = recordRefresh(state, key, res);
    });
    await pollIssues(auth);
    if (session.token() === auth) drawAccessories();
  }

  const safely = <A extends unknown[], R>(label: string, fn: (...args: A) => Promise<R>) =>
    async (...args: A): Promise<R | undefined> => {
      try {
        return await fn(...args);
      } catch (e) {
        leo.log("error", label + ": " + (e instanceof Error ? e.message : String(e)));
        return undefined;
      }
    };

  const startPolling = (): void => {
    if (timer === null && session.token() !== null) timer = leo.timer(POLL_INTERVAL_SEC, safely("poll", poll));
  };
  const stopPolling = (): void => {
    timer?.cancel();
    timer = null;
  };

  // ---- Views ----------------------------------------------------------------

  async function openView(agent: AgentRef, slot: SlotID): Promise<void> {
    const key = agentKey(agent);
    register(slot, key);
    const auth = session.token();
    if (auth === null) return session.renderSignedOut(slot);
    leo.render(slot, { type: "Loading" });
    if (!state.agents.has(key)) await syncAgents();
    const snapshot = state.agents.get(key);
    const mapped = snapshot === undefined ? null : mappedOf(snapshot);
    const base = { agent, slot, mapped, rateLimitedUntil: scheduler.pausedUntil() };
    if (snapshot === undefined || mapped === null) return leo.render(slot, viewRoot({ ...base, status: null, error: null, reviews: null }));

    const loaded = await (async () => {
      const status = await fetchPrStatus(client, auth, snapshot);
      if (!status.ok || status.value.kind !== "pr") return { status, reviews: null };
      const threads = await fetchReviewThreads(client, auth, mapped, status.value.pr.number);
      return { status, reviews: threads.ok ? threads.value : (null as ReviewState | null) };
    })();
    if (session.token() !== auth) return; // signed out meanwhile: the session already redrew this slot
    if (loaded.status.ok) {
      state = withStatus(state, key, loaded.status.value);
      drawAccessories([key]);
    }
    const model = loaded.status.ok
      ? { ...base, status: loaded.status.value, error: null, reviews: loaded.reviews }
      : { ...base, status: null, error: loaded.status.error, reviews: null };
    leo.render(slot, viewRoot({ ...model, rateLimitedUntil: scheduler.pausedUntil() }));
  }

  // ---- Slots ----------------------------------------------------------------

  async function activate(slot?: SlotID): Promise<void> {
    await ready();
    startPolling();
    if (slot === undefined) return;
    if (slot.kind === "section") {
      register(slot, null);
      return renderIssues(ctx, slot, () => retryCommandAction(COMMANDS.newAgentFromIssue, slot));
    }
    if (slot.kind !== "accessory") return;
    const key = agentKey(slot.agent);
    register(slot, key);
    if (session.token() === null) return session.renderSignedOut(slot);
    if (!state.agents.has(key)) await syncAgents();
    await refreshAgent(key);
  }

  const refreshAll = async (): Promise<void> => {
    const entries = [...state.slots.values()];
    await Promise.all(
      entries.map((e) => {
        if (e.slot.kind === "view") return openView(e.slot.agent, e.slot);
        if (e.slot.kind === "accessory" && e.agentKey !== null) return refreshAgent(e.agentKey);
        if (e.slot.kind === "section") return renderIssues(ctx, e.slot, () => retryCommandAction(COMMANDS.newAgentFromIssue, e.slot));
        return Promise.resolve();
      }),
    );
  };

  session.subscribe((event) => {
    drawn = new Map(); // the session drew over the slots; forget what we think they show
    if (event === "signedOut") {
      stopPolling();
      state = withoutStatuses(state);
      return;
    }
    startPolling();
    void safely("refresh after sign-in", refreshAll)();
  });

  const ctx: Ctx = { leo, clock, client, scheduler, session, openView };

  leo.on("activate", safely("activate", activate));
  leo.on("agentsChanged", safely("agentsChanged", onAgentsChanged));
  leo.on("viewOpened", safely("viewOpened", async (agent, slot) => {
    await ready();
    startPolling();
    if (slot.kind === "view" && slot.viewID === VIEW_ID) await openView(agent, slot);
  }));
  leo.on("command", safely("command", async (id, slot) => {
    await ready();
    await runCommand(ctx, id, slot);
  }));
  leo.on("callback", async (id, payload) => {
    try {
      await ready();
      return await runCallback(ctx, id, payload);
    } catch (e) {
      leo.log("error", "callback " + id + ": " + (e instanceof Error ? e.message : String(e)));
      return null;
    }
  });
}
