// Host integration fixture: floods the app with 1 MB log requests, to trip the
// per-handler request/byte quota.
leo.on("agentsChanged", () => {
  for (;;) leo.log("info", "x".repeat(1e6));
});
leo.log("info", "flood:loaded");
