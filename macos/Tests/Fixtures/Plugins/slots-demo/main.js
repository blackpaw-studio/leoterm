// Visual-check fixture contributing every slot: an agent view, a row
// accessory, a sidebar section and two palette commands (one renders a list
// with a pushView action, one is callback-only). Loaded through a dev folder;
// it never ships in the app bundle. A test run copies this folder, changing
// `id`, `name` and BADGE, to get several plugins on one row.
const BADGE = { sfSymbol: "checkmark.circle.fill", text: "PR #12", color: "success", help: "3 of 3 checks passed" };

leo.on("activate", (slot) => {
  if (slot.kind === "accessory") {
    leo.render(slot, { type: "Accessory", ...BADGE });
  } else if (slot.kind === "section") {
    leo.render(slot, {
      type: "List",
      sections: [{
        title: "Recent",
        items: [
          { id: "b1", title: "main · build 412", subtitle: "passed 3 min ago", sfSymbol: "checkmark.circle",
            accessories: [{ text: "ok", color: "success" }] },
          { id: "b2", title: "feat/slots · build 413", subtitle: "running", sfSymbol: "arrow.triangle.2.circlepath",
            accessories: [{ text: "run", color: "running" }] },
          { id: "b3", title: "fix/palette · build 411", subtitle: "failed", sfSymbol: "xmark.circle",
            accessories: [{ text: "fail", color: "failure" }] },
        ],
      }],
    });
  }
});

leo.on("viewOpened", (agent, slot) => {
  leo.render(slot, [
    { type: "Detail", markdown: "# Slots Demo\nOpened on **" + agent.name + "** (" + agent.machine + ").\n\n- A pane view\n- Drawn natively\n- Never a web view" },
    {
      type: "List",
      sections: [
        {
          title: "Checks",
          items: [
            { id: "build", title: "build", subtitle: "passed in 2m 10s", sfSymbol: "checkmark.circle.fill", accessories: [{ text: "2m", color: "neutral" }], actions: [{ type: "copy", text: "build" }] },
            { id: "lint", title: "lint", subtitle: "failed: 3 warnings", sfSymbol: "xmark.circle.fill", accessories: [{ text: "failed", color: "failure" }], actions: [{ type: "pushView", node: { type: "EmptyState", title: "Lint log", message: "A pushed view: Back returns here." } }] },
            { id: "deploy", title: "deploy", subtitle: "waiting", sfSymbol: "clock", accessories: [{ text: "queued", color: "warning" }], actions: [{ type: "openURL", url: "https://example.com" }] },
          ],
        },
      ],
    },
  ]);
});

leo.on("command", (id, slot) => {
  // copy-ping is callback-only: it never renders its palette slot.
  if (id !== "open-prs") return;
  leo.render(slot, {
    type: "List",
    sections: [{
      items: [
        { id: "pr1", title: "#1042 Add plugin sidebar sections", subtitle: "evan · ready for review", sfSymbol: "arrow.triangle.pull",
          actions: [{ type: "pushView", title: "Show Details", node: {
            type: "Detail",
            markdown: "# #1042 Add plugin sidebar sections\n\nCollapsible, below the agent list.\n\n- Collapsed by default\n- Hide per plugin\n",
          } }] },
        { id: "pr2", title: "#1043 Palette commands", subtitle: "evan · draft", sfSymbol: "arrow.triangle.pull",
          actions: [{ type: "copy", text: "#1043" }] },
      ],
    }],
  });
});
