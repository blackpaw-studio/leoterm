import { describe, expect, it } from "vitest";
import { createGitHubClient } from "../src/github/client";
import { renderReviewForm, selectedThreadIds, handleSendComments, SEND_COMMENTS } from "../src/ui/reviews";
import type { ReviewThread } from "../src/reviews/threads";
import { asResponse } from "./fixtureLoader";
import { createStubLeo } from "./stubLeo";
import page1 from "./fixtures/review-threads-page1.json";
import page2 from "./fixtures/review-threads-page2.json";
import type { Form } from "../../sdk/leo";

const AGENT = { machine: "m", name: "a" };
const PR = { owner: "o", repo: "r", number: 12 };
const th = (over: Partial<ReviewThread>): ReviewThread => ({
  id: "T", path: "a.ts", line: 4, originalLine: 4, isOutdated: false, author: "al", body: "b", url: "u", ...over,
});

describe("renderReviewForm", () => {
  it("shows an empty state when there are no threads", () => {
    expect(renderReviewForm(AGENT, PR, [])).toMatchObject({ type: "EmptyState", title: "No unresolved review comments" });
  });

  it("builds one checked checkbox per thread, labelled path:line · @author: first 120 chars, plus a submit", () => {
    const form = renderReviewForm(AGENT, PR, [th({ id: "T1", body: "x".repeat(200) })]) as Form;
    const [box, submit] = form.fields;
    expect(box).toMatchObject({ id: "T1", type: "checkbox", checked: true });
    expect(box.label).toBe("a.ts:4 · @al: " + "x".repeat(120));
    expect(submit).toMatchObject({
      type: "submit",
      label: "Send Comments to Agent",
      action: { type: "callback", id: SEND_COMMENTS, payload: { agent: AGENT, pr: PR } },
    });
  });

  it("flattens newlines in the label", () => {
    const form = renderReviewForm(AGENT, PR, [th({ body: "a\nb" })]) as Form;
    expect(form.fields[0].label).toBe("a.ts:4 · @al: a b");
  });
});

describe("selectedThreadIds", () => {
  it("accepts string and boolean checkbox values", () => {
    expect(selectedThreadIds({ A: "true", B: "false", C: true, D: false, E: "on", F: "" })).toEqual(["A", "C", "E"]);
  });
});

describe("handleSendComments", () => {
  const setup = () => {
    const stub = createStubLeo();
    stub.route("POST", "https://api.github.com/graphql", asResponse(page1), asResponse(page2));
    return { stub, client: createGitHubClient(stub.leo, stub.clock) };
  };

  it("resolves to one sendToAgent with the selected threads", async () => {
    const { client } = setup();
    const action = await handleSendComments(client, "tok", { agent: AGENT, pr: PR, formId: "f", values: { T1: "true", T3: "false", T4: "true" } });
    expect(action).toMatchObject({ type: "sendToAgent", agent: AGENT, title: "Send Comments to Agent" });
    const text = (action as { text: string }).text;
    expect(text.split("\n")[0]).toBe("2 review comments on PR #12 (o/r):");
    expect(text).toContain("## src/a.ts\n- L3 @ghost: Missing null check.");
    expect(text).not.toContain("Outdated nit");
  });

  it("returns null when nothing is selected", async () => {
    const { client, stub } = setup();
    expect(await handleSendComments(client, "tok", { agent: AGENT, pr: PR, formId: "f", values: { T1: "false" } })).toBeNull();
    expect(stub.fetches).toHaveLength(0);
  });

  it("returns null when the payload is malformed", async () => {
    const { client } = setup();
    expect(await handleSendComments(client, "tok", { nope: 1 })).toBeNull();
  });

  it("returns null when the refetch fails", async () => {
    const stub = createStubLeo();
    stub.route("POST", "https://api.github.com/graphql", { status: 401, body: {} });
    const client = createGitHubClient(stub.leo, stub.clock);
    expect(await handleSendComments(client, "tok", { agent: AGENT, pr: PR, values: { T1: "true" } })).toBeNull();
  });
});
