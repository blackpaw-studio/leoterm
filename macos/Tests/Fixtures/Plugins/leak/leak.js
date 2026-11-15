// Host integration fixture: allocates (and touches) memory without end, to trip the memory cap.
const hoard = [];
leo.on("agentsChanged", () => {
  for (;;) hoard.push(new Float64Array(1 << 20).fill(1));
});
leo.log("info", "leak:loaded");
