import { spawnAgent } from "../../../sdk/actions";
import type { Action, AgentSnapshot } from "../../../sdk/leo";
import type { ParseRepo } from "../repoTypes";
import { truncateUtf8, utf8Length } from "./utf8";
import { branchName } from "./branchName";
import type { Issue } from "./list";
import { quoteUntrusted } from "../untrusted";

export const NEW_AGENT_TITLE = "New Agent from Issue";
const BODY_MAX_BYTES = 8 * 1024;
const TRUNCATED = "…(truncated)";

const capBody = (body: string): string =>
  utf8Length(body) <= BODY_MAX_BYTES ? body : truncateUtf8(body, BODY_MAX_BYTES) + TRUNCATED;

/** The issue URL, then title and body quoted as untrusted content (the body is capped at 8 KB first). */
export const issuePrompt = (issue: Issue): string =>
  `GitHub issue ${issue.url}\n\n` + quoteUntrusted("issue", `${issue.title}\n\n${capBody(issue.body)}`);

/** The raw `repo` string of an existing agent on the same repo (so the daemon sees a form it already uses), else `owner/repo`. */
export const resolveRepoString = (ownerRepo: string, agents: readonly AgentSnapshot[], parseRepo: ParseRepo): string => {
  const want = ownerRepo.toLowerCase();
  const match = agents.find((a) => {
    const parsed = a.repo === null ? null : parseRepo(a.repo);
    return parsed !== null && `${parsed.owner}/${parsed.repo}`.toLowerCase() === want;
  });
  return match?.repo ?? ownerRepo;
};

export const issueSpawnAction = (issue: Issue, agents: readonly AgentSnapshot[], parseRepo: ParseRepo): Action =>
  spawnAgent(
    { repo: resolveRepoString(issue.repo, agents, parseRepo), branch: branchName(issue.number, issue.title), prompt: issuePrompt(issue) },
    { title: NEW_AGENT_TITLE },
  );
