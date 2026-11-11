// Host integration fixture: proves the bridge round trip in both directions.
leo.on("activate", () => {
  leo.log("info", "echo:activate");
  leo.fetch("https://example.test/echo").then((r) => leo.log("info", "echo:fetched " + r.status));
});
leo.on("agentsChanged", () => leo.log("info", "echo:agents"));
leo.log("info", "echo:loaded");
