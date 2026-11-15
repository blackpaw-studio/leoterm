// Host integration fixture: a handler that never returns, to trip the CPU watchdog.
leo.on("agentsChanged", () => {
  for (;;) {}
});
leo.log("info", "spin:loaded");
