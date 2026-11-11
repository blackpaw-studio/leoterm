// Visual-check fixture for the agent view (slot 1) and the row accessory
// (slot 2). Loaded through a dev folder; it never ships in the app bundle.
// A test run copies this folder, changing `id`, `name` and BADGE, to get
// several plugins on one row.
const BADGE = { sfSymbol: "checkmark.circle.fill", text: "PR #12", color: "success", help: "3 of 3 checks passed" };

leo.on("activate", (slot) => {
  if (slot && slot.kind === "accessory") leo.render(slot, { type: "Accessory", ...BADGE });
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
