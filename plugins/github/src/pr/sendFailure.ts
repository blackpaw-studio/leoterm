import { sendToAgent } from "../../../sdk/actions";
import type { Action, AgentRef } from "../../../sdk/leo";
import type { GitHubClient } from "../github/client";
import { ok, type Result } from "../github/errors";
import type { RepoRef } from "../repoRef";
import type { CheckItem } from "./checks";
import { excerptLog, utf8Length } from "./logExcerpt";

export const MAX_LOG_BYTES = 5 * 1024 * 1024;
const SEND_TITLE = "Send Failure to Agent";

export interface FailureContext {
  readonly agent: AgentRef;
  readonly repo: RepoRef;
  readonly branch: string;
  readonly prNumber: number;
  readonly check: CheckItem;
}

type LogOutcome = { readonly kind: "log"; readonly excerpt: string } | { readonly kind: "unavailable"; readonly reason: string };

const unavailable = (reason: string): LogOutcome => ({ kind: "unavailable", reason });

/**
 * Fetches the job log. The host follows the 302 to the log host (dropping Authorization on the
 * host change); a hop outside the manifest allowlist rejects, which surfaces as Transport.
 * Only Unauthorized and RateLimited are returned as errors; everything else is a fallback reason.
 */
async function fetchLog(client: GitHubClient, auth: string, ctx: FailureContext): Promise<Result<LogOutcome>> {
  const { check, repo } = ctx;
  if (check.source === "status") return ok(unavailable("commit status has no log"));
  if (check.source !== "actions" || check.jobId === null) return ok(unavailable("not a GitHub Actions check"));
  const res = await client.request("GET", "/repos/" + repo.owner + "/" + repo.repo + "/actions/jobs/" + check.jobId + "/logs", { auth });
  if (res.ok) {
    return ok(utf8Length(res.value.text) > MAX_LOG_BYTES ? unavailable("log is larger than 5 MB") : { kind: "log", excerpt: excerptLog(res.value.text) });
  }
  const err = res.error;
  if (err.kind === "Unauthorized" || err.kind === "RateLimited") return res;
  if (err.kind === "Transport") return ok(unavailable("log download failed: " + err.reason));
  return ok(unavailable(err.status === 404 || err.status === 410 ? "log not found or expired" : "log request failed (HTTP " + err.status + ")"));
}

function buildMessage(ctx: FailureContext, outcome: LogOutcome): string {
  const { check, repo, branch, prNumber } = ctx;
  const head = 'Check "' + check.name + '" failed on PR #' + prNumber + " (" + repo.owner + "/" + repo.repo + "@" + branch + ")";
  const body = outcome.kind === "log" ? "```\n" + outcome.excerpt + "\n```" : "(log unavailable: " + outcome.reason + ")";
  return head + "\n" + (check.url === null ? "" : check.url + "\n") + "\n" + body;
}

/** The follow-up action for a `send-failure` callback: one sendToAgent (still gated by the confirmation sheet). */
export async function sendFailure(client: GitHubClient, auth: string, ctx: FailureContext): Promise<Result<Action>> {
  const log = await fetchLog(client, auth, ctx);
  if (!log.ok) return log;
  return ok(sendToAgent(ctx.agent, buildMessage(ctx, log.value), { title: SEND_TITLE }));
}

/** "Open in Browser" for a check; null when the URL isn't https (the host would reject it). */
export function openInBrowserAction(url: string | null): Action | null {
  return url !== null && url.startsWith("https://") ? { type: "openURL", url, title: "Open in Browser" } : null;
}
