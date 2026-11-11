import { openURL } from "../../../sdk/actions";
import type { Action, AgentRef, ErrorNode, JSONValue, Leo, SlotID } from "../../../sdk/leo";
import type { GitHubClient } from "../github/client";
import type { GitHubError } from "../github/errors";
import { createPrForm, createdView, inlineError, notPushedView, CREATE_PR_PICK, CREATE_PR_SUBMIT } from "../ui/prForms";
import { humaniseBranch } from "./branch";

export { CREATE_PR_PICK, CREATE_PR_SUBMIT, humaniseBranch };

export interface CreatePrDeps {
  readonly leo: Pick<Leo, "render">;
  readonly client: GitHubClient;
  readonly auth: string | null;
}

interface PrContext {
  readonly agent: AgentRef;
  readonly slot: SlotID;
  readonly owner: string;
  readonly repo: string;
  readonly branch: string;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string";

const parseAgent = (v: unknown): AgentRef | null =>
  isObj(v) && isStr(v.machine) && isStr(v.name) ? { machine: v.machine, name: v.name } : null;

const parseSlot = (v: unknown): SlotID | null => (isObj(v) && isStr(v.kind) ? (v as unknown as SlotID) : null);

const parseContext = (v: unknown): PrContext | null => {
  if (!isObj(v)) return null;
  const agent = parseAgent(v.agent);
  const slot = parseSlot(v.slot);
  if (!agent || !slot || !isStr(v.owner) || !isStr(v.repo) || !isStr(v.branch)) return null;
  return { agent, slot, owner: v.owner, repo: v.repo, branch: v.branch };
};

const describeError = (e: GitHubError): string => {
  switch (e.kind) {
    case "Unauthorized":
      return "Sign in to GitHub to continue.";
    case "RateLimited":
      return "GitHub rate limit reached. Try again later.";
    case "Http":
      return `GitHub returned ${e.status}.`;
    case "Transport":
      return `Couldn't reach GitHub (${e.reason}).`;
  }
};

const errorNode = (message: string, retry: Action): ErrorNode => ({ type: "Error", message, retry });

/** `create-pr:pick`: fetch the default branch, then render the form into the slot carried in the payload. */
export async function pickCreatePr(deps: CreatePrDeps, payload: JSONValue): Promise<void> {
  const ctx = parseContext(payload);
  if (!ctx) return;
  const res = await deps.client.request<{ default_branch?: unknown }>("GET", `/repos/${ctx.owner}/${ctx.repo}`, { auth: deps.auth });
  if (!res.ok) {
    const retry: Action = { type: "callback", id: CREATE_PR_PICK, payload, title: "Retry" };
    deps.leo.render(ctx.slot, errorNode(describeError(res.error), retry));
    return;
  }
  const base = res.value.json?.default_branch;
  deps.leo.render(ctx.slot, createPrForm({ ...ctx, defaultBase: isStr(base) ? base : "main" }));
}

interface Submission {
  readonly title: string;
  readonly body: string;
  readonly base: string;
  readonly draft: boolean;
}

const parseSubmission = (values: unknown): Submission | null => {
  if (!isObj(values) || !isStr(values.title) || !isStr(values.base)) return null;
  return { title: values.title, body: isStr(values.body) ? values.body : "", base: values.base, draft: values.draft !== false };
};

type Outcome =
  | { readonly kind: "created"; readonly number: number; readonly url: string }
  | { readonly kind: "notPushed" }
  | { readonly kind: "invalid"; readonly message: string }
  | { readonly kind: "error"; readonly error: GitHubError };

/** A 422 on `head`, or "No commits between", means the branch isn't on origin (yet). */
export const isNotPushed = (bodyText: string): { readonly notPushed: boolean; readonly message: string } => {
  let json: unknown;
  try {
    json = JSON.parse(bodyText);
  } catch {
    return { notPushed: false, message: "GitHub rejected the pull request." };
  }
  const message = isObj(json) && isStr(json.message) ? json.message : "GitHub rejected the pull request.";
  const errors = isObj(json) && Array.isArray(json.errors) ? json.errors : [];
  const headField = errors.some((e) => isObj(e) && e.field === "head");
  return { notPushed: headField || message.startsWith("No commits between"), message };
};

async function createPull(deps: CreatePrDeps, ctx: PrContext, s: Submission): Promise<Outcome> {
  const res = await deps.client.request<{ number?: unknown; html_url?: unknown }>("POST", `/repos/${ctx.owner}/${ctx.repo}/pulls`, {
    auth: deps.auth,
    body: { title: s.title, body: s.body, head: ctx.branch, base: s.base, draft: s.draft },
  });
  if (res.ok) {
    const { number, html_url } = res.value.json ?? {};
    return typeof number === "number" && isStr(html_url) ? { kind: "created", number, url: html_url } : { kind: "invalid", message: "Unexpected response from GitHub." };
  }
  if (res.error.kind === "Http" && res.error.status === 422) {
    const c = isNotPushed(res.error.body);
    return c.notPushed ? { kind: "notPushed" } : { kind: "invalid", message: c.message };
  }
  return { kind: "error", error: res.error };
}

/** `create-pr:submit` (form callback `{formId, values, payload}`). Renders the result; returns a follow-up `openURL` on success. */
export async function submitCreatePr(deps: CreatePrDeps, raw: JSONValue): Promise<Action | undefined> {
  if (!isObj(raw)) return undefined;
  const ctx = parseContext(raw.payload);
  const s = parseSubmission(raw.values);
  if (!ctx || !s) return undefined;
  const outcome = await createPull(deps, ctx, s);
  switch (outcome.kind) {
    case "created":
      deps.leo.render(ctx.slot, createdView(outcome.number));
      return openURL(outcome.url, { title: "Open Pull Request" });
    case "notPushed":
      deps.leo.render(ctx.slot, notPushedView(ctx.agent, ctx.branch));
      return undefined;
    case "invalid":
    case "error": {
      const message = outcome.kind === "invalid" ? outcome.message : describeError(outcome.error);
      deps.leo.render(ctx.slot, [inlineError(message), createPrForm({ ...ctx, defaultBase: s.base, prefill: s })]);
      return undefined;
    }
  }
}
