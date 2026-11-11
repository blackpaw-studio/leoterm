import type { AgentSnapshot, Node, SlotID, SlotRoot } from "../../sdk/leo";
import type { Ctx } from "./context";
import { COMMANDS } from "./config";
import { fetchAssignedIssues, type Issue } from "./issues/list";
import { findOpenPr } from "./pr/match";
import { parseRepo } from "./repoRef";
import { agentKey } from "./state";
import { issuesList } from "./ui/issues";
import { createPrPicker, mappedAgents, openPrPicker, type PrLink } from "./ui/prForms";
import { emptyRoot, errorRoot, retryCommandAction } from "./ui/view";

export const issuesRoot = (issues: readonly Issue[], agents: readonly AgentSnapshot[]): SlotRoot =>
  issues.length === 0 ? emptyRoot("No assigned issues", undefined, "checkmark.circle") : issuesList(issues, agents, parseRepo);

const NO_AGENTS: Node = emptyRoot("No agents on a GitHub branch", "Open a pull request from an agent that has a github.com repo and a branch.", "arrow.triangle.branch");

/** Issues into a slot (the sidebar section or the `new-agent-from-issue` palette page). */
export async function renderIssues(ctx: Ctx, slot: SlotID, retry: () => ReturnType<typeof retryCommandAction>): Promise<void> {
  const auth = ctx.session.token();
  if (auth === null) return ctx.session.renderSignedOut(slot);
  ctx.leo.render(slot, { type: "Loading" });
  const res = await fetchAssignedIssues(ctx.client, auth);
  if (ctx.session.token() !== auth) return;
  if (!res.ok) return ctx.leo.render(slot, errorRoot(res.error, retry()));
  ctx.leo.render(slot, issuesRoot(res.value, await ctx.leo.agents.list()));
}

async function openPr(ctx: Ctx, auth: string, slot: SlotID): Promise<void> {
  const entries = mappedAgents(await ctx.leo.agents.list(), parseRepo);
  const found = await Promise.all(entries.map((e) => findOpenPr(ctx.client, auth, { owner: e.owner, repo: e.repo }, e.branch)));
  if (ctx.session.token() !== auth) return;
  const prs = new Map<string, PrLink>(
    entries.flatMap((e, i) => {
      const res = found[i];
      return res.ok && res.value !== null ? [[agentKey(e.agent), { number: res.value.number, url: res.value.htmlUrl }] as const] : [];
    }),
  );
  ctx.leo.render(slot, entries.length === 0 ? NO_AGENTS : openPrPicker(entries, prs));
}

async function createPr(ctx: Ctx, slot: SlotID): Promise<void> {
  const entries = mappedAgents(await ctx.leo.agents.list(), parseRepo);
  ctx.leo.render(slot, entries.length === 0 ? NO_AGENTS : createPrPicker(entries, slot));
}

async function signIn(ctx: Ctx, slot: SlotID): Promise<void> {
  if (ctx.session.token() !== null) return ctx.leo.render(slot, emptyRoot("Signed in to GitHub", undefined, "checkmark.circle"));
  await ctx.session.startSignIn(slot);
}

async function signOut(ctx: Ctx, slot: SlotID): Promise<void> {
  await ctx.session.signOut();
  ctx.leo.render(slot, emptyRoot("Signed out", "Your GitHub token was removed.", "person.crop.circle.badge.xmark"));
}

/** Palette commands. Everything but sign-in/out needs a token; without one the slot shows the sign-in state. */
export async function runCommand(ctx: Ctx, id: string, slot: SlotID | undefined): Promise<void> {
  if (slot === undefined || slot.kind !== "palette") return;
  ctx.session.track(slot);
  if (id === COMMANDS.signIn) return signIn(ctx, slot);
  if (id === COMMANDS.signOut) return signOut(ctx, slot);
  const auth = ctx.session.token();
  if (auth === null) return ctx.session.renderSignedOut(slot);
  switch (id) {
    case COMMANDS.newAgentFromIssue:
      return renderIssues(ctx, slot, () => retryCommandAction(id, slot));
    case COMMANDS.openPr:
      return openPr(ctx, auth, slot);
    case COMMANDS.createPr:
      return createPr(ctx, slot);
  }
}
