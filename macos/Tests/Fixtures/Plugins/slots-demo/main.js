// Visual fixture for the sidebar-section and palette-command slots (M4 steps 4.4, 4.5).
leo.on("activate", (slot) => {
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
});

leo.on("command", (id, slot) => {
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
