import type { AgentRef, Leo, SlotID } from "../../sdk/leo";
import type { Session } from "./auth/session";
import type { Clock } from "./clock";
import type { GitHubClient } from "./github/client";
import type { Scheduler } from "./scheduler";

/** What commands and callbacks need from the running plugin. Built once in plugin.ts. */
export interface Ctx {
  readonly leo: Leo;
  readonly clock: Clock;
  /** Observed client: 401s and rate limits are handled before a failed result returns. */
  readonly client: GitHubClient;
  readonly scheduler: Scheduler;
  readonly session: Session;
  /** (Re)load the `github` view into a slot. */
  openView(agent: AgentRef, slot: SlotID): Promise<void>;
}
