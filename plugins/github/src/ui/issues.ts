import { openURL } from "../../../sdk/actions";
import type { AgentSnapshot, List } from "../../../sdk/leo";
import type { Issue } from "../issues/list";
import { issueSpawnAction } from "../issues/spawn";
import type { ParseRepo } from "../repoTypes";

/** Shared by the `assigned-issues` section and the `new-agent-from-issue` palette slot. */
export const issuesList = (issues: readonly Issue[], agents: readonly AgentSnapshot[], parseRepo: ParseRepo): List => ({
  type: "List",
  sections: [
    {
      id: "issues",
      items: issues.map((issue) => ({
        id: `${issue.repo}#${issue.number}`,
        title: issue.title,
        subtitle: `${issue.repo} #${issue.number}`,
        sfSymbol: "smallcircle.filled.circle",
        actions: [
          issueSpawnAction(issue, agents, parseRepo),
          ...(issue.url.startsWith("https://") ? [openURL(issue.url, { title: "Open in Browser" })] : []),
        ],
      })),
    },
  ],
});
