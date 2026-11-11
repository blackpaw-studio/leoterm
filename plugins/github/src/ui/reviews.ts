import { callback, pushView, sendToAgent } from "../../../sdk/actions";
import type { Action, AgentRef, Field, JSONValue, Node } from "../../../sdk/leo";
import type { GitHubClient } from "../github/client";
import { describeError } from "../github/describe";
import { buildBatchMessage } from "../reviews/batch";
import { fetchReviewThreads, type PrCoords, type ReviewThread } from "../reviews/threads";

export const SEND_COMMENTS = "send-comments";
const FORM_ID = "review-threads";
const SUBMIT_LABEL = "Send Comments to Agent";
const SNIPPET_CHARS = 120;

const label = (t: ReviewThread): string => {
  const snippet = t.body.replace(/\s+/g, " ").trim().slice(0, SNIPPET_CHARS);
  return `${t.path}:${t.line ?? t.originalLine ?? "?"} · @${t.author}: ${snippet}`;
};

/** A form with one checked checkbox per thread, or an empty state. */
export function renderReviewForm(agent: AgentRef, pr: PrCoords, threads: readonly ReviewThread[]): Node {
  if (threads.length === 0) return { type: "EmptyState", title: "No unresolved review comments", sfSymbol: "checkmark.bubble" };
  const boxes: Field[] = threads.map((t) => ({ id: t.id, type: "checkbox", label: label(t), checked: true }));
  const submit: Field = {
    id: "submit",
    type: "submit",
    label: SUBMIT_LABEL,
    action: callback(SEND_COMMENTS, {
      agent: { machine: agent.machine, name: agent.name },
      pr: { owner: pr.owner, repo: pr.repo, number: pr.number },
    }),
  };
  return { type: "Form", id: FORM_ID, title: "Review Comments", fields: [...boxes, submit] };
}

const isChecked = (v: JSONValue | undefined): boolean => v === true || (typeof v === "string" && v !== "" && v !== "false");

export const selectedThreadIds = (values: { readonly [key: string]: JSONValue }): string[] =>
  Object.entries(values).filter(([, v]) => isChecked(v)).map(([id]) => id);

const isObject = (v: unknown): v is { [key: string]: JSONValue } => typeof v === "object" && v !== null && !Array.isArray(v);

/**
 * Submit handler. The host sends a form's submit as `{formId, values, payload}`, where `payload` is the
 * submit action's own payload (agent and PR).
 * Re-fetches the threads (field ids are thread ids) so the payload stays small, then returns one sendToAgent.
 * A failed refetch returns an Error view with Retry, so the click never silently does nothing.
 */
export async function handleSendComments(
  client: GitHubClient,
  auth: string | null,
  payload: JSONValue,
): Promise<Action | null> {
  if (!isObject(payload) || !isObject(payload.values) || !isObject(payload.payload)) return null;
  const { values } = payload;
  const { agent, pr } = payload.payload;
  if (!isObject(agent) || !isObject(pr)) return null;
  if (typeof agent.machine !== "string" || typeof agent.name !== "string") return null;
  if (typeof pr.owner !== "string" || typeof pr.repo !== "string" || typeof pr.number !== "number") return null;
  const ids = new Set(selectedThreadIds(values));
  if (ids.size === 0) return null;

  const coords: PrCoords = { owner: pr.owner, repo: pr.repo, number: pr.number };
  const res = await fetchReviewThreads(client, auth, coords, coords.number);
  if (!res.ok) {
    const retry = callback(SEND_COMMENTS, payload, { title: "Retry" });
    return pushView({ type: "Error", message: describeError(res.error), retry });
  }
  const text = buildBatchMessage(coords, res.value.threads.filter((t) => ids.has(t.id)));
  return text === null ? null : sendToAgent({ machine: agent.machine, name: agent.name }, text, { title: SUBMIT_LABEL });
}
