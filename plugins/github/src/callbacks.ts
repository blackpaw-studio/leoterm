import type { CallbackResult, JSONValue } from "../../sdk/leo";
import { SIGN_IN_CALLBACK } from "./auth/session";
import { runCommand } from "./commands";
import type { Ctx } from "./context";
import { isObj, isStr, parseAgentRef, parseSlot } from "./payload";
import { parseRepo } from "./repoRef";
import type { CheckItem } from "./pr/checks";
import { CREATE_PR_PICK, CREATE_PR_SUBMIT, pickCreatePr, submitCreatePr } from "./pr/createPr";
import { sendFailure } from "./pr/sendFailure";
import { handleSendComments, SEND_COMMENTS } from "./ui/reviews";
import { RETRY_COMMAND, RETRY_VIEW, SEND_FAILURE } from "./ui/view";

const SOURCES: ReadonlySet<string> = new Set(["actions", "other", "status"]);
const STATES: ReadonlySet<string> = new Set(["failure", "running", "success", "neutral"]);

/** Re-validates a check carried in a `send-failure` payload; it goes into a request path, so trust nothing. */
const parseCheck = (v: unknown): CheckItem | null => {
  if (!isObj(v) || !isStr(v.id) || !isStr(v.name) || !isStr(v.state) || !isStr(v.source)) return null;
  if (!STATES.has(v.state) || !SOURCES.has(v.source)) return null;
  const jobId = v.jobId === null ? null : Number.isSafeInteger(v.jobId) ? (v.jobId as number) : undefined;
  if (jobId === undefined || (v.url !== null && !isStr(v.url))) return null;
  return { id: v.id, name: v.name, state: v.state as CheckItem["state"], url: v.url, source: v.source as CheckItem["source"], jobId };
};

async function onSendFailure(ctx: Ctx, auth: string, payload: JSONValue): Promise<CallbackResult> {
  if (!isObj(payload)) return null;
  const agent = parseAgentRef(payload.agent);
  const check = parseCheck(payload.check);
  const repo = isStr(payload.owner) && isStr(payload.repo) ? parseRepo(payload.owner + "/" + payload.repo) : null;
  if (!agent || !check || !repo || !isStr(payload.branch) || typeof payload.prNumber !== "number") return null;
  const res = await ctx.scheduler.user(() =>
    sendFailure(ctx.client, auth, { agent, repo, branch: payload.branch as string, prNumber: payload.prNumber as number, check }),
  );
  return res.ok ? res.value : null;
}

/** Routes the plugin's callback ids. Every network call goes through the user lane. */
export async function runCallback(ctx: Ctx, id: string, payload: JSONValue): Promise<CallbackResult> {
  const { session, scheduler, client, leo } = ctx;
  const body = isObj(payload) ? payload : {};
  if (id === SIGN_IN_CALLBACK) {
    const slot = parseSlot(body.slot);
    if (slot) await session.startSignIn(slot);
    return null;
  }
  if (id === RETRY_VIEW) {
    const agent = parseAgentRef(body.agent);
    const slot = parseSlot(body.slot);
    if (agent && slot) await ctx.openView(agent, slot);
    return null;
  }
  if (id === RETRY_COMMAND) {
    if (isStr(body.commandID)) await runCommand(ctx, body.commandID, parseSlot(body.slot) ?? undefined);
    return null;
  }
  const auth = session.token();
  if (auth === null) return null;
  switch (id) {
    case SEND_FAILURE:
      return onSendFailure(ctx, auth, payload);
    case SEND_COMMENTS:
      return scheduler.user(() => handleSendComments(client, auth, payload));
    case CREATE_PR_PICK:
      return scheduler.user(() => pickCreatePr({ leo, client, auth }, payload)).then(() => null);
    case CREATE_PR_SUBMIT:
      return scheduler.user(() => submitCreatePr({ leo, client, auth }, payload));
    default:
      return null;
  }
}
