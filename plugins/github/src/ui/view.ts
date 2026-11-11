import { callback } from "../../../sdk/actions";
import type { Action, AgentRef, EmptyState, JSONValue, ListItem, Node, SlotID, SlotRoot } from "../../../sdk/leo";
import { describeError } from "../github/describe";
import type { GitHubError } from "../github/errors";
import type { CheckItem, CheckState } from "../pr/checks";
import { openInBrowserAction } from "../pr/sendFailure";
import type { PullRequest } from "../pr/match";
import { renderReviewForm } from "./reviews";
import type { ReviewState } from "../reviews/threads";
import type { PrStatus } from "../state";
import { formatResetTime } from "./accessory";
import { CREATE_PR_PICK, type MappedAgent } from "./prForms";

export const SEND_FAILURE = "send-failure";
export const RETRY_VIEW = "retry-view";
export const RETRY_COMMAND = "retry-command";

const CHECK_SYMBOL: Readonly<Record<CheckState, string>> = {
  success: "checkmark.circle.fill",
  failure: "xmark.circle.fill",
  running: "arrow.triangle.2.circlepath",
  neutral: "circle",
};
const CHECK_LABEL: Readonly<Record<CheckState, string>> = { success: "passed", failure: "failed", running: "running", neutral: "neutral" };
const DECISION_LABEL: Readonly<Record<string, string>> = {
  APPROVED: "Approved",
  CHANGES_REQUESTED: "Changes requested",
  REVIEW_REQUIRED: "Review required",
};

export interface ViewModel {
  readonly agent: AgentRef;
  readonly slot: SlotID;
  readonly mapped: MappedAgent | null;
  /** null when the PR lookup failed (see `error`). */
  readonly status: PrStatus | null;
  readonly error: GitHubError | null;
  /** null when the review comments couldn't be loaded. */
  readonly reviews: ReviewState | null;
  /** Epoch ms the poll lane is paused until, or null. */
  readonly rateLimitedUntil: number | null;
}

const empty = (title: string, message?: string, sfSymbol?: string, actions?: Action[]): EmptyState => ({
  type: "EmptyState",
  title,
  message,
  sfSymbol,
  ...(actions ? { actions } : {}),
});

export const rateLimitBanner = (until: number): Node =>
  empty("Rate limited until " + formatResetTime(until), "Polling resumes automatically.", "clock");

const escapeMd = (text: string): string => text.replace(/([\\`*_[\]])/g, "\\$1");

const prDetail = (pr: PullRequest, decision: string | null): Node => {
  const flags = [pr.draft ? "Draft" : "Open", ...(decision !== null && DECISION_LABEL[decision] ? [DECISION_LABEL[decision]] : [])];
  const link = pr.htmlUrl.startsWith("https://") ? `\n\n[View on GitHub](${pr.htmlUrl})` : "";
  return { type: "Detail", markdown: `### #${pr.number} ${escapeMd(pr.title)}\n\n${flags.join(" · ")}${link}` };
};

const checkItem = (model: ViewModel, mapped: MappedAgent, pr: PullRequest, check: CheckItem): ListItem => {
  const browser = openInBrowserAction(check.url);
  const send: Action | null =
    check.state === "failure"
      ? callback(
          SEND_FAILURE,
          {
            agent: { machine: model.agent.machine, name: model.agent.name },
            owner: mapped.owner,
            repo: mapped.repo,
            branch: mapped.branch,
            prNumber: pr.number,
            check: { ...check },
          } as JSONValue,
          { title: "Send Failure to Agent", sfSymbol: "paperplane" },
        )
      : null;
  return {
    id: check.id,
    title: check.name,
    sfSymbol: CHECK_SYMBOL[check.state],
    accessories: [{ text: CHECK_LABEL[check.state], color: check.state }],
    actions: [...(send ? [send] : []), ...(browser ? [browser] : [])],
  };
};

const noPr = (model: ViewModel, mapped: MappedAgent): Node =>
  empty("No open pull request", `${mapped.owner}/${mapped.repo}@${mapped.branch}`, "arrow.triangle.pull", [
    callback(
      CREATE_PR_PICK,
      { agent: { ...model.agent }, slot: model.slot as unknown as JSONValue, owner: mapped.owner, repo: mapped.repo, branch: mapped.branch },
      { title: "Create Pull Request" },
    ),
  ]);

const withBanner = (model: ViewModel, nodes: readonly Node[]): SlotRoot => [
  ...(model.rateLimitedUntil === null ? [] : [rateLimitBanner(model.rateLimitedUntil)]),
  ...nodes,
];

const prNodes = (model: ViewModel, mapped: MappedAgent, pr: PullRequest, checks: readonly CheckItem[]): Node[] => [
  prDetail(pr, model.reviews?.reviewDecision ?? null),
  ...(checks.length === 0
    ? []
    : [{ type: "List" as const, sections: [{ id: "checks", title: "Checks", items: checks.map((c) => checkItem(model, mapped, pr, c)) }] }]),
  model.reviews === null
    ? empty("Couldn't load review comments", undefined, "exclamationmark.bubble")
    : renderReviewForm(model.agent, { owner: mapped.owner, repo: mapped.repo, number: pr.number }, model.reviews.threads),
];

/** The `github` view: `[banner | Error, PR Detail, checks List, review Form | empty state]`. */
export function viewRoot(model: ViewModel): SlotRoot {
  const { mapped, status } = model;
  if (mapped === null) return withBanner(model, [empty("This agent isn't on a GitHub branch", undefined, "arrow.triangle.branch")]);
  if (status === null) {
    const retry = callback(RETRY_VIEW, { agent: { ...model.agent }, slot: model.slot as unknown as JSONValue }, { title: "Retry" });
    const message = model.error === null ? "Couldn't load GitHub data." : describeError(model.error);
    return withBanner(model, [{ type: "Error", message, retry }]);
  }
  if (status.kind === "pr") return withBanner(model, prNodes(model, mapped, status.pr, status.checks));
  return withBanner(model, [status.kind === "noPr" ? noPr(model, mapped) : empty("This agent isn't on a GitHub branch")]);
}

export const retryCommandAction = (commandID: string, slot: SlotID): Action =>
  callback(RETRY_COMMAND, { commandID, slot: slot as unknown as JSONValue }, { title: "Retry" });

export const errorRoot = (error: GitHubError, retry: Action): Node => ({ type: "Error", message: describeError(error), retry });

export const emptyRoot = empty;
