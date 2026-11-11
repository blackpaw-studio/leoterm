import { sendToAgent } from "../../../sdk/actions";
import type { Action, AgentRef } from "../../../sdk/leo";
import type { ApiResponse, GitHubClient } from "../github/client";
import { ok, type Result } from "../github/errors";
import type { RepoRef } from "../repoRef";
import type { CheckItem } from "./checks";
import { plainText, quoteUntrusted } from "../untrusted";
import { excerptLog, utf8Length } from "./logExcerpt";

export const MAX_LOG_BYTES = 5 * 1024 * 1024;
/** Only the tail of a log is ever used, and the follow-up callback has a 30 s deadline. */
export const LOG_TAIL_BYTES = 64 * 1024;
const CHECK_NAME_MAX_CHARS = 100;
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

/** The log's total size from a 206's `Content-Range` (`bytes <start>-<end>/<total>`). */
const rangeTotal = (res: ApiResponse): number | null => {
  const m = /\/(\d+)$/.exec((res.headers["content-range"] ?? "").trim());
  return m ? Number(m[1]) : null;
};

/** Where a 206's range starts (the `Content-Range` header is `bytes <start>-<end>/<total>`). */
const rangeStart = (res: ApiResponse): number | null => {
  const m = /^bytes (\d+)-/i.exec(res.headers["content-range"] ?? "");
  return m ? Number(m[1]) : null;
};

/** A 200 is the whole log (the range was ignored); a 206 is its tail, whose first line may be cut. */
function logOutcome(res: ApiResponse): LogOutcome {
  if (res.status !== 206) {
    return utf8Length(res.text) > MAX_LOG_BYTES ? unavailable("log is larger than 5 MB") : { kind: "log", excerpt: excerptLog(res.text) };
  }
  const start = rangeStart(res);
  const whole = start === 0;
  const text = whole ? res.text : res.text.slice(res.text.indexOf("\n") + 1);
  return { kind: "log", excerpt: excerptLog(text) };
}

/**
 * Fetches the tail of the job log. The host follows the 302 to the log host (dropping Authorization on the
 * host change); a hop outside the manifest allowlist rejects, which surfaces as Transport.
 * Only Unauthorized and RateLimited are returned as errors; everything else is a fallback reason.
 *
 * Azure blob storage (the log host) answers `bytes=N-` and `bytes=a-b` with 206 but ignores a suffix range
 * (`bytes=-N`) and sends the whole log, so the tail takes two requests: a `bytes=0-0` probe whose
 * Content-Range gives the size, then `bytes=<size - tail>-`. A host that ignores ranges answers the probe
 * with a 200, which is already the whole log.
 */
async function fetchLog(client: GitHubClient, auth: string, ctx: FailureContext): Promise<Result<LogOutcome>> {
  const { check, repo } = ctx;
  if (check.source === "status") return ok(unavailable("commit status has no log"));
  if (check.source !== "actions" || check.jobId === null) return ok(unavailable("not a GitHub Actions check"));
  const path = "/repos/" + repo.owner + "/" + repo.repo + "/actions/jobs/" + check.jobId + "/logs";
  const ranged = (range: string) => client.request("GET", path, { auth, headers: { Range: range } });
  const probe = await ranged("bytes=0-0");
  const res = probe.ok && probe.value.status === 206 ? await ranged(tailRange(probe.value)) : probe;
  if (res.ok) return ok(logOutcome(res.value));
  const err = res.error;
  if (err.kind === "Unauthorized" || err.kind === "RateLimited") return res;
  if (err.kind === "Transport") return ok(unavailable("log download failed: " + err.reason));
  if (err.status === 416) return ok(unavailable("log is empty"));
  return ok(unavailable(err.status === 404 || err.status === 410 ? "log not found or expired" : "log request failed (HTTP " + err.status + ")"));
}

/** `bytes=<first byte of the last LOG_TAIL_BYTES>-`; the whole log (`bytes=0-`) when the size is unknown or small. */
const tailRange = (probe: ApiResponse): string => "bytes=" + Math.max(0, (rangeTotal(probe) ?? 0) - LOG_TAIL_BYTES) + "-";

function buildMessage(ctx: FailureContext, outcome: LogOutcome): string {
  const { check, repo, branch, prNumber } = ctx;
  const name = plainText(check.name).slice(0, CHECK_NAME_MAX_CHARS);
  const head = 'Check "' + name + '" failed on PR #' + prNumber + " (" + repo.owner + "/" + repo.repo + "@" + branch + ")";
  const body = outcome.kind === "log" ? quoteUntrusted("ci-log", outcome.excerpt) : "(log unavailable: " + outcome.reason + ")";
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
