// Host integration fixture: allocates ~400 MB inside a fast handler and returns
// (so the CPU watchdog never trips and the helper is idle afterwards). Only a
// memory check that runs on `done` or while idle catches it.
const hoard = [];
leo.on("agentsChanged", () => {
  for (let i = 0; i < 50; i++) hoard.push(new Float64Array(1 << 20).fill(1));
});
leo.log("info", "hog:loaded");
