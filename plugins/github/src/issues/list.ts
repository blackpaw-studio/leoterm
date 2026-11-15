import type { GitHubClient } from "../github/client";
import { fail, ok, type Result } from "../github/errors";

export interface Issue {
  readonly number: number;
  readonly title: string;
  readonly body: string;
  readonly url: string;
  /** `owner/repo` as GitHub spells it. */
  readonly repo: string;
}

export const ASSIGNED_ISSUES_PATH = "/issues?filter=assigned&state=open&per_page=100";

const str = (v: unknown): string => (typeof v === "string" ? v : "");

const toIssue = (raw: unknown): Issue | null => {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (r.pull_request !== undefined && r.pull_request !== null) return null;
  const repo = str((r.repository as { full_name?: unknown } | undefined)?.full_name);
  if (typeof r.number !== "number" || !repo) return null;
  return { number: r.number, title: str(r.title), body: str(r.body), url: str(r.html_url), repo };
};

/** Open issues assigned to the signed-in user: first page only, PRs dropped, ETag-cached. */
export async function fetchAssignedIssues(client: GitHubClient, auth: string | null): Promise<Result<Issue[]>> {
  const res = await client.getCached<unknown[]>(ASSIGNED_ISSUES_PATH, { auth });
  if (!res.ok) return fail(res.error);
  const json = res.value.json;
  const issues = Array.isArray(json) ? json.map(toIssue).filter((i): i is Issue => i !== null) : [];
  return ok(issues);
}
