import type { GitHubClient } from "../github/client";
import { ok, type Result } from "../github/errors";
import type { RepoRef } from "../repoRef";

export type CheckState = "failure" | "running" | "success" | "neutral";

export interface CheckItem {
  /** Check run id as a string, or `status:<id>` for a commit status. */
  readonly id: string;
  readonly name: string;
  readonly state: CheckState;
  readonly url: string | null;
  /** `actions` runs have a log fetchable by job id (check run id == job id). */
  readonly source: "actions" | "other" | "status";
  readonly jobId: number | null;
}

type Raw = Record<string, unknown>;
const isObject = (v: unknown): v is Raw => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

const FAILING_CONCLUSIONS: ReadonlySet<string> = new Set(["failure", "timed_out", "cancelled", "action_required", "startup_failure"]);
const PASSING_CONCLUSIONS: ReadonlySet<string> = new Set(["success", "neutral", "skipped"]);

function runState(status: unknown, conclusion: unknown): CheckState {
  if (typeof conclusion === "string" && FAILING_CONCLUSIONS.has(conclusion)) return "failure";
  if (status !== "completed") return "running";
  return typeof conclusion === "string" && PASSING_CONCLUSIONS.has(conclusion) ? "success" : "neutral";
}

function statusState(state: unknown): CheckState {
  if (state === "failure" || state === "error") return "failure";
  if (state === "pending") return "running";
  return state === "success" ? "success" : "neutral";
}

function toRun(raw: unknown): CheckItem | null {
  if (!isObject(raw) || typeof raw.id !== "number" || typeof raw.name !== "string") return null;
  const isActions = isObject(raw.app) && raw.app.slug === "github-actions";
  return {
    id: String(raw.id),
    name: raw.name,
    state: runState(raw.status, raw.conclusion),
    url: str(raw.html_url) ?? str(raw.details_url),
    source: isActions ? "actions" : "other",
    jobId: isActions ? raw.id : null,
  };
}

function toStatus(raw: unknown): CheckItem | null {
  if (!isObject(raw) || typeof raw.id !== "number" || typeof raw.context !== "string") return null;
  return { id: "status:" + raw.id, name: raw.context, state: statusState(raw.state), url: str(raw.target_url), source: "status", jobId: null };
}

const collect = <T>(json: unknown, key: string, map: (raw: unknown) => T | null): T[] => {
  const list = isObject(json) && Array.isArray(json[key]) ? (json[key] as unknown[]) : [];
  return list.map(map).filter((v): v is T => v !== null);
};

/** Precedence failure > running > success > neutral. An empty list is neutral. */
export function combineState(checks: readonly CheckItem[]): CheckState {
  if (checks.some((c) => c.state === "failure")) return "failure";
  if (checks.some((c) => c.state === "running")) return "running";
  return checks.some((c) => c.state === "success") ? "success" : "neutral";
}

/**
 * A push and a pull_request workflow run on one head SHA each report a check with the same name. Keep the newest
 * (highest id) per name and source so the list shows each check once, and a stale run can't mask the current result.
 */
function latestPerName(runs: readonly CheckItem[]): CheckItem[] {
  const newest = new Map<string, CheckItem>();
  for (const run of runs) {
    const key = run.source + ":" + run.name;
    const seen = newest.get(key);
    if (seen === undefined || Number(run.id) > Number(seen.id)) newest.set(key, run);
  }
  return [...newest.values()];
}

export const findCheck = (checks: readonly CheckItem[], id: string): CheckItem | undefined => checks.find((c) => c.id === id);

/** Check runs plus commit statuses for `sha`, both ETag-cached. Only the first page of runs (100) is read. */
export async function fetchChecks(client: GitHubClient, auth: string, ref: RepoRef, sha: string): Promise<Result<CheckItem[]>> {
  const base = "/repos/" + ref.owner + "/" + ref.repo + "/commits/" + sha;
  const [runs, status] = await Promise.all([
    client.getCached<unknown>(base + "/check-runs?per_page=100", { auth }),
    client.getCached<unknown>(base + "/status", { auth }),
  ]);
  if (!runs.ok) return runs;
  if (!status.ok) return status;
  // The combined status of a commit with no statuses reads "pending"; only listed statuses count.
  return ok([...latestPerName(collect(runs.value.json, "check_runs", toRun)), ...collect(status.value.json, "statuses", toStatus)]);
}
