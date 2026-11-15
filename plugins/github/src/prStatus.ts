import type { AgentSnapshot } from "../../sdk/leo";
import type { GitHubClient } from "./github/client";
import { ok, type Result } from "./github/errors";
import { fetchChecks } from "./pr/checks";
import { findOpenPr } from "./pr/match";
import { parseRepo } from "./repoRef";
import type { PrStatus } from "./state";
import { mappedAgents, type MappedAgent } from "./ui/prForms";

/** The agent's github.com repo and branch, or null when it can't have a PR. */
export const mappedOf = (agent: AgentSnapshot): MappedAgent | null => mappedAgents([agent], parseRepo)[0] ?? null;

/** PR and combined checks for one agent's branch. Unmapped agents cost no request. */
export async function fetchPrStatus(client: GitHubClient, auth: string, agent: AgentSnapshot): Promise<Result<PrStatus>> {
  const mapped = mappedOf(agent);
  if (mapped === null) return ok({ kind: "unmapped" });
  const ref = { owner: mapped.owner, repo: mapped.repo };
  const pr = await findOpenPr(client, auth, ref, mapped.branch);
  if (!pr.ok) return pr;
  if (pr.value === null) return ok({ kind: "noPr" });
  const checks = await fetchChecks(client, auth, ref, pr.value.headSha);
  return checks.ok ? ok({ kind: "pr", pr: pr.value, checks: checks.value }) : checks;
}
