import type { GitHubClient } from "../github/client";
import { fail, http, ok, type Result } from "../github/errors";

export interface RepoCoords {
  readonly owner: string;
  readonly repo: string;
}
export interface PrCoords extends RepoCoords {
  readonly number: number;
}

export interface ReviewThread {
  readonly id: string;
  readonly path: string;
  /** null when the thread's line no longer exists in the diff (outdated). */
  readonly line: number | null;
  readonly originalLine: number | null;
  readonly isOutdated: boolean;
  readonly author: string;
  readonly body: string;
  readonly url: string;
}

export interface ReviewState {
  /** APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or null. */
  readonly reviewDecision: string | null;
  /** Unresolved threads only, in server order. */
  readonly threads: readonly ReviewThread[];
}

const PAGE_SIZE = 100;
const MAX_PAGES = 5;
const GHOST = "ghost";

const QUERY = `query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewDecision reviewThreads(first:${PAGE_SIZE},after:$after){pageInfo{hasNextPage endCursor} nodes{id isResolved isOutdated path line originalLine comments(first:1){nodes{author{login} body url}}}}}}}`;

interface RawThread {
  id: string;
  isResolved: boolean;
  isOutdated: boolean;
  path: string;
  line: number | null;
  originalLine: number | null;
  comments?: { nodes?: Array<{ author: { login: string } | null; body: string; url: string } | null> };
}
interface RawPage {
  repository: {
    pullRequest: {
      reviewDecision: string | null;
      reviewThreads: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: Array<RawThread | null> };
    } | null;
  } | null;
}

const toThread = (raw: RawThread): ReviewThread => {
  const first = raw.comments?.nodes?.[0];
  return {
    id: raw.id,
    path: raw.path,
    line: raw.line ?? null,
    originalLine: raw.originalLine ?? null,
    isOutdated: raw.isOutdated,
    author: first?.author?.login ?? GHOST,
    body: first?.body ?? "",
    url: first?.url ?? "",
  };
};

/**
 * Unresolved review threads for a PR (`reviewThreads` has no isResolved argument,
 * so resolved ones are filtered here), following pages up to a cap.
 */
export async function fetchReviewThreads(
  client: GitHubClient,
  auth: string | null,
  repo: RepoCoords,
  number: number,
): Promise<Result<ReviewState>> {
  const threads: ReviewThread[] = [];
  let reviewDecision: string | null = null;
  let after: string | null = null as string | null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const variables = { owner: repo.owner, name: repo.repo, number, after };
    const res: Result<RawPage> = await client.graphql<RawPage>(QUERY, variables, { auth });
    if (!res.ok) return res;
    const pr: NonNullable<RawPage["repository"]>["pullRequest"] | undefined = res.value?.repository?.pullRequest;
    if (!pr) return fail(http(404, "Pull request not found"));
    reviewDecision = pr.reviewDecision ?? null;
    for (const raw of pr.reviewThreads.nodes) if (raw && !raw.isResolved) threads.push(toThread(raw));
    const hasNextPage: boolean = pr.reviewThreads.pageInfo.hasNextPage;
    const endCursor: string | null = pr.reviewThreads.pageInfo.endCursor;
    if (!hasNextPage || !endCursor) break;
    after = endCursor;
  }
  return ok({ reviewDecision, threads });
}
