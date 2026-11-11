import type { PrCoords, ReviewThread } from "./threads";

const lineOf = (t: ReviewThread): number => t.line ?? t.originalLine ?? 0;

const bullet = (t: ReviewThread): string => {
  const marker = t.line === null && t.isOutdated ? " (outdated)" : "";
  const [first, ...rest] = t.body.trim().split(/\r?\n/);
  return [`- L${lineOf(t)}${marker} @${t.author}: ${first}`, ...rest.map((l) => `  ${l}`)].join("\n");
};

const byPathThenLine = (a: ReviewThread, b: ReviewThread): number =>
  a.path < b.path ? -1 : a.path > b.path ? 1 : lineOf(a) - lineOf(b);

/** One message for the agent: count line, then threads grouped by file (sorted by path, then line). Null when empty. */
export function buildBatchMessage(pr: PrCoords, threads: readonly ReviewThread[]): string | null {
  if (threads.length === 0) return null;
  const sorted = [...threads].sort(byPathThenLine);
  const paths = [...new Set(sorted.map((t) => t.path))];
  const sections = paths.map((path) =>
    [`## ${path}`, ...sorted.filter((t) => t.path === path).map(bullet)].join("\n"),
  );
  const n = threads.length;
  const head = `${n} review comment${n === 1 ? "" : "s"} on PR #${pr.number} (${pr.owner}/${pr.repo}):`;
  return [head, ...sections].join("\n\n");
}
