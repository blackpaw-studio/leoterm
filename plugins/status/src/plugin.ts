import type { AgentRef, Leo, PaneSlot, SlotID, TimerHandle, UsageSnapshot } from "../../sdk/leo";
import { buildBody, type Where } from "./body";
import type { Clock } from "./clock";
import { buildSummary } from "./summary";

export const PANE_ID = "status";
/** Reset countdowns tick this often (the host's minimum for `after` is 1 s). */
export const TICK_SEC = 60;

type Part = PaneSlot["part"];

/** What one agent's pane shows; replaced, never mutated, on each change. */
interface AgentState {
  readonly agent: AgentRef;
  readonly slots: Readonly<Partial<Record<Part, PaneSlot>>>;
  /** `undefined`: not read yet. `"denied"`: the read failed. */
  readonly usage: UsageSnapshot | null | "denied" | undefined;
  readonly where: Where;
  /** Bumped per refresh so a slow read cannot overwrite a newer one. */
  readonly generation: number;
}

const keyOf = (a: AgentRef): string => `${a.machine}/${a.name}`;

const isStatusPane = (slot: SlotID): slot is PaneSlot => slot.kind === "pane" && slot.id === PANE_ID;

const errorMessage = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export function createPlugin(leo: Leo, clock: Clock): void {
  let states: ReadonlyMap<string, AgentState> = new Map();
  let tick: TimerHandle | undefined;

  const put = (state: AgentState): void => {
    states = new Map(states).set(keyOf(state.agent), state);
  };

  const paint = (state: AgentState): void => {
    const { summary, body } = state.slots;
    if (state.usage === undefined) return;
    if (state.usage === "denied") {
      if (summary) leo.render(summary, { type: "Text", runs: [{ text: "Usage unavailable", tone: "secondary" }] });
      if (body) leo.render(body, { type: "EmptyState", title: "Usage unavailable" });
      return;
    }
    if (summary) leo.render(summary, buildSummary(state.usage));
    if (body) leo.render(body, buildBody(state.usage, state.where, clock.now()));
  };

  // One pending tick at most: every refresh restarts it, and it re-arms itself while any agent is held.
  const armTick = (): void => {
    tick?.cancel();
    tick = leo.after(TICK_SEC, () => {
      states.forEach(paint);
      armTick();
    });
  };

  const readWhere = async (agent: AgentRef): Promise<Where> => {
    try {
      const match = (await leo.agents.list()).find((a) => a.machine === agent.machine && a.name === agent.name);
      return { workspace: match?.workspace, branch: match?.branch ?? undefined };
    } catch (e) {
      leo.log("warn", `agents.list failed: ${errorMessage(e)}`);
      return {};
    }
  };

  const readUsage = async (agent: AgentRef): Promise<UsageSnapshot | null | "denied"> => {
    try {
      return await leo.agents.usage(agent);
    } catch (e) {
      leo.log("error", `agents.usage failed: ${errorMessage(e)}`);
      return "denied";
    }
  };

  const refresh = async (agent: AgentRef): Promise<void> => {
    const current = states.get(keyOf(agent));
    if (!current) return;
    const generation = current.generation + 1;
    put({ ...current, generation });
    const [usage, where] = await Promise.all([readUsage(agent), readWhere(agent)]);
    const latest = states.get(keyOf(agent));
    if (!latest || latest.generation !== generation) return;
    const next = { ...latest, usage, where };
    put(next);
    paint(next);
    armTick();
  };

  leo.on("viewOpened", async (agent, slot) => {
    if (!isStatusPane(slot)) return;
    const existing = states.get(keyOf(agent));
    put({
      agent,
      slots: { ...existing?.slots, [slot.part]: slot },
      usage: existing?.usage,
      where: existing?.where ?? {},
      generation: existing?.generation ?? 0,
    });
    await refresh(agent);
  });

  leo.on("usageChanged", async (agent) => {
    await refresh(agent);
  });
}
