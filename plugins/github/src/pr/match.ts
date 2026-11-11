import type { GitHubClient } from "../github/client";
import { ok, type Result } from "../github/errors";
import type { RepoRef } from "../repoRef";

export interface PullRequest {
  readonly number: number;
  readonly title: string;
  readonly draft: boolean;
  readonly htmlUrl: string;
  readonly headSha: string;
  readonly updatedAt: string;
}

type Raw = Record<string, unknown>;
const isObject = (v: unknown): v is Raw => typeof v === "object" && v !== null && !Array.isArray(v);

function toPullRequest(raw: unknown): PullRequest | null {
  if (!isObject(raw) || typeof raw.number !== "number") return null;
  const sha = isObject(raw.head) ? raw.head.sha : undefined;
  if (typeof sha !== "string" || typeof raw.html_url !== "string") return null;
  return {
    number: raw.number,
    title: typeof raw.title === "string" ? raw.title : "",
    draft: raw.draft === true,
    htmlUrl: raw.html_url,
    headSha: sha,
    updatedAt: typeof raw.updated_at === "string" ? raw.updated_at : "",
  };
}

/** The open PR whose head is `owner:branch`; with several, the most recently updated. ETag-cached. */
export async function findOpenPr(
  client: GitHubClient,
  auth: string,
  ref: RepoRef,
  branch: string,
): Promise<Result<PullRequest | null>> {
  const head = ref.owner + ":" + encodeURIComponent(branch);
  const path = "/repos/" + ref.owner + "/" + ref.repo + "/pulls?head=" + head + "&state=open&per_page=10";
  const res = await client.getCached<unknown>(path, { auth });
  if (!res.ok) return res;
  const list = Array.isArray(res.value.json) ? res.value.json : [];
  const prs = list.map(toPullRequest).filter((p): p is PullRequest => p !== null);
  // ISO-8601 UTC timestamps sort lexicographically.
  const newest = prs.reduce<PullRequest | null>((best, p) => (best === null || p.updatedAt > best.updatedAt ? p : best), null);
  return ok(newest);
}
