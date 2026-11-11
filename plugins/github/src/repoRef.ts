/** A github.com repository, with the case the agent's `repo` string used. */
export interface RepoRef {
  readonly owner: string;
  readonly repo: string;
}

const SEGMENT = "[A-Za-z0-9_.-]+";
const SLUG = `(${SEGMENT})/(${SEGMENT}?)(?:\\.git)?/?`;
const HOST = "(?:www\\.)?github\\.com";
const FORMS: readonly RegExp[] = [
  new RegExp(`^${SLUG}$`),
  new RegExp(`^(?:https?://(?:[^/@\\s]+@)?|ssh://git@|git@)?${HOST}[/:]${SLUG}$`, "i"),
];

const isDots = (s: string): boolean => /^\.+$/.test(s);

/** Parses the repo forms the daemon reports. Returns null for paths, other hosts and extra segments. */
export function parseRepo(raw: string): RepoRef | null {
  const text = raw.trim();
  if (text === "" || text.startsWith("/") || text.startsWith("~") || text.startsWith(".")) return null;
  for (const form of FORMS) {
    const m = form.exec(text);
    if (m && !isDots(m[1]) && !isDots(m[2]) && m[2] !== ".git") return { owner: m[1], repo: m[2] };
  }
  return null;
}

export const sameRepo = (a: RepoRef, b: RepoRef): boolean =>
  a.owner.toLowerCase() === b.owner.toLowerCase() && a.repo.toLowerCase() === b.repo.toLowerCase();

/** The slice of an agent snapshot that decides whether it can have a PR. */
export interface RepoBranch {
  readonly repo: string | null;
  readonly branch: string | null;
}

export const isMapped = (agent: RepoBranch): boolean =>
  agent.repo !== null && parseRepo(agent.repo) !== null && (agent.branch ?? "") !== "";
