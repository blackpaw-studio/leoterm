import { callback, openURL, sendToAgent } from "../../../sdk/actions";
import type { AgentRef, AgentSnapshot, EmptyState, Form, JSONValue, List, Node, SlotID } from "../../../sdk/leo";
import type { ParseRepo } from "../repoTypes";
import { humaniseBranch } from "../pr/branch";

export const CREATE_PR_PICK = "create-pr:pick";
export const CREATE_PR_SUBMIT = "create-pr:submit";

export interface MappedAgent {
  readonly agent: AgentRef;
  readonly owner: string;
  readonly repo: string;
  readonly branch: string;
}
export interface PrLink {
  readonly number: number;
  readonly url: string;
}

/** Agents on a github.com repo with a non-empty branch. */
export const mappedAgents = (agents: readonly AgentSnapshot[], parseRepo: ParseRepo): MappedAgent[] =>
  agents.flatMap((a) => {
    const parsed = a.repo === null ? null : parseRepo(a.repo);
    return parsed && a.branch ? [{ agent: { machine: a.machine, name: a.name }, owner: parsed.owner, repo: parsed.repo, branch: a.branch }] : [];
  });

const agentKey = (a: AgentRef): string => a.name;
const row = (e: MappedAgent) => ({
  id: `${e.agent.machine}/${e.agent.name}`,
  title: e.agent.name,
  sfSymbol: "arrow.triangle.pull",
});

/** First palette page of `open-pr`: one row per mapped agent. `prs` is keyed by agent name. */
export const openPrPicker = (entries: readonly MappedAgent[], prs: ReadonlyMap<string, PrLink>): List => ({
  type: "List",
  sections: [
    {
      items: entries.map((e) => {
        const pr = prs.get(agentKey(e.agent));
        return pr
          ? { ...row(e), subtitle: `#${pr.number} · ${e.owner}/${e.repo}`, actions: [openURL(pr.url, { title: "Open Pull Request" })] }
          : { ...row(e), subtitle: "No open PR" };
      }),
    },
  ],
});

/** First palette page of `create-pr`. `slot` is echoed back in the callback so the form can be rendered there. */
export const createPrPicker = (entries: readonly MappedAgent[], slot: SlotID): List => ({
  type: "List",
  sections: [
    {
      items: entries.map((e) => ({
        ...row(e),
        subtitle: `${e.owner}/${e.repo}@${e.branch}`,
        actions: [callback(
          CREATE_PR_PICK,
          { agent: { ...e.agent }, slot: slot as unknown as JSONValue, owner: e.owner, repo: e.repo, branch: e.branch },
          { title: "Create Pull Request" },
        )],
      })),
    },
  ],
});

export interface CreatePrFormInput extends MappedAgent {
  readonly slot: SlotID;
  readonly defaultBase: string;
  /** Values to restore after a failed submit. */
  readonly prefill?: { readonly title: string; readonly body: string; readonly base: string; readonly draft: boolean };
}

export const createPrForm = (input: CreatePrFormInput): Form => {
  const p = input.prefill;
  return {
    type: "Form",
    id: "create-pr",
    title: `Create PR · ${input.owner}/${input.repo}@${input.branch}`,
    fields: [
      { id: "title", type: "text", label: "Title", value: p?.title ?? humaniseBranch(input.branch) },
      { id: "body", type: "textArea", label: "Description", value: p?.body ?? "" },
      { id: "base", type: "text", label: "Base branch", value: p?.base ?? input.defaultBase },
      { id: "draft", type: "checkbox", label: "Draft", checked: p?.draft ?? true },
      {
        id: "submit",
        type: "submit",
        label: "Create Pull Request",
        action: callback(CREATE_PR_SUBMIT, {
          agent: { ...input.agent },
          slot: input.slot as unknown as JSONValue,
          owner: input.owner,
          repo: input.repo,
          branch: input.branch,
        }),
      },
    ],
  };
};

const empty = (title: string, message?: string, sfSymbol?: string): EmptyState => ({ type: "EmptyState", title, message, sfSymbol });

export const createdView = (number: number): Node => empty(`Created #${number}`, "Opening it in your browser.", "checkmark.circle.fill");

export const notPushedView = (agent: AgentRef, branch: string): Node[] => [
  empty("Branch isn't pushed", `${branch} has no commits on origin to open a pull request from.`, "exclamationmark.triangle"),
  {
    type: "List",
    sections: [
      {
        items: [
          {
            id: "ask-push",
            title: "Ask Agent to Push",
            sfSymbol: "arrow.up.circle",
            actions: [sendToAgent(agent, `Please push branch ${branch} to origin so I can open a PR.`, { title: "Ask Agent to Push" })],
          },
        ],
      },
    ],
  },
];

export const inlineError = (message: string): Node => empty("Couldn't create the pull request", message, "xmark.circle.fill");
