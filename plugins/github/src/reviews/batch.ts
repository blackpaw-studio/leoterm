import { truncateUtf8, utf8Length } from "../issues/utf8";
import { fenceUntrusted, plainText, UNTRUSTED_NOTICE } from "../untrusted";
import type { PrCoords, ReviewThread } from "./threads";

/** Per comment. The host caps agent text at 32 KB; the whole message stays well under it. */
export const COMMENT_MAX_BYTES = 2 * 1024;
export const MESSAGE_MAX_BYTES = 24 * 1024;
const PATH_MAX_CHARS = 200;
const TRUNCATED = "…(truncated)";

const lineOf = (t: ReviewThread): number => t.line ?? t.originalLine ?? 0;

const capComment = (body: string): string => {
  const text = body.trim();
  return utf8Length(text) <= COMMENT_MAX_BYTES ? text : truncateUtf8(text, COMMENT_MAX_BYTES) + TRUNCATED;
};

/** Plugin text (position and author) above the comment, which sits alone in its own fence. */
const entry = (t: ReviewThread): string => {
  const marker = t.line === null && t.isOutdated ? " (outdated)" : "";
  return `- L${lineOf(t)}${marker} @${plainText(t.author)}:\n${fenceUntrusted("review-comment", capComment(t.body))}`;
};

const heading = (path: string): string => "## " + plainText(path).slice(0, PATH_MAX_CHARS);

const byPathThenLine = (a: ReviewThread, b: ReviewThread): number =>
  a.path < b.path ? -1 : a.path > b.path ? 1 : lineOf(a) - lineOf(b);

const omitted = (n: number): string => `(${n} more omitted)`;

/**
 * One message for the agent: count line, the untrusted notice, then threads grouped by file (sorted by
 * path, then line), each comment in its own fence. Stops before `MESSAGE_MAX_BYTES` and says how many
 * comments it left out. Null when empty.
 */
export function buildBatchMessage(pr: PrCoords, threads: readonly ReviewThread[]): string | null {
  if (threads.length === 0) return null;
  const sorted = [...threads].sort(byPathThenLine);
  const n = threads.length;
  const head = `${n} review comment${n === 1 ? "" : "s"} on PR #${pr.number} (${pr.owner}/${pr.repo}):\n${UNTRUSTED_NOTICE}`;
  const reserve = utf8Length("\n\n" + omitted(n));

  const parts: string[] = [head];
  let used = utf8Length(head);
  let included = 0;
  for (const [i, t] of sorted.entries()) {
    const newFile = i === 0 || sorted[i - 1].path !== t.path;
    const piece = (newFile ? "\n\n" + heading(t.path) + "\n" : "\n") + entry(t);
    if (used + utf8Length(piece) + reserve > MESSAGE_MAX_BYTES) break;
    parts.push(piece);
    used += utf8Length(piece);
    included += 1;
  }
  return included === n ? parts.join("") : parts.join("") + "\n\n" + omitted(n - included);
}
