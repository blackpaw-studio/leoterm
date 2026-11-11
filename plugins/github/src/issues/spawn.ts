import { spawnAgent } from "../../../sdk/actions";
import type { Action, AgentSnapshot } from "../../../sdk/leo";
import type { ParseRepo } from "../repoTypes";
import { truncateUtf8, utf8Length } from "./utf8";
import { branchName } from "./branchName";
import type { Issue } from "./list";

export const NEW_AGENT_TITLE = "New Agent from Issue";
const BODY_MAX_BYTES = 8 * 1024;
const TRUNCATED = "…(truncated)";

export const issuePrompt = (issue: Issue): string => {
  const head = `${issue.title}\n${issue.url}\n\n`;
  if (utf8Length(issue.body) <= BODY_MAX_BYTES) return head + issue.body;
  return head + truncateUtf8(issue.body, BODY_MAX_BYTES) + TRUNCATED;
};

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
