// Agent-pane fixture. Draws a summary and a body that show every Text tone and
// the Meter's edge cases, and follows `usageChanged` through `leo.agents.usage`.
// For the visual check, copy this folder to a scratch dev folder and rename
// pane-demo.manifest.json to leo-plugin.json (the test bundle flattens its
// resources, so two files named leo-plugin.json would collide). Never bundled. Read
// directly by the host integration test (the real JavaScriptCore host).
const TONES = ["secondary", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "success", "warning", "failure"];
const slots = new Map();
const key = (agent) => agent.machine + "/" + agent.name;

const toneRuns = () => TONES.flatMap((tone, i) => [
  { text: tone, tone, weight: i % 2 === 0 ? "regular" : "semibold", mono: i % 3 === 0 },
  { text: " " },
]);

const summary = (tokens) => [
  { type: "Text", runs: [{ text: "pane-demo", tone: "accent1", weight: "semibold" }, { text: " " + tokens + " tok", tone: "secondary", mono: true }] },
  { type: "Meter", max: 100, segments: [{ value: 30, tone: "accent1" }, { value: 20, tone: "accent2" }], label: "50%", help: "Half full" },
  { type: "Accessory", sfSymbol: "checkmark.circle.fill", text: "ok", color: "success", help: "An accessory in the summary" },
];

const body = (tokens) => [
  { type: "Text", runs: toneRuns() },
  { type: "Text", runs: [{ text: "Tokens " }, { text: String(tokens), tone: "accent3", mono: true, weight: "semibold" }] },
  // Partly filled, with a label and tooltip.
  { type: "Meter", max: 100, label: "context 45%", help: "Context window", segments: [
    { value: 10, tone: "accent1" }, { value: 15, tone: "accent2" }, { value: 20, tone: "accent3" } ] },
  // Segments sum past max: the overflow is cut.
  { type: "Meter", max: 100, label: "overflow", segments: [{ value: 80, tone: "success" }, { value: 80, tone: "failure" }] },
  // Exactly full, one segment.
  { type: "Meter", max: 100, label: "full", segments: [{ value: 100, tone: "warning" }] },
  // A sliver, and a zero segment that draws nothing.
  { type: "Meter", max: 100, label: "sliver", segments: [{ value: 0.5, tone: "accent4" }, { value: 0, tone: "accent5" }] },
  // The most segments a Meter may hold.
  { type: "Meter", max: 80, label: "8 segments", segments: TONES.slice(0, 8).map((tone) => ({ value: 10, tone })) },
];

function renderAll(agent, tokens) {
  const entry = slots.get(key(agent));
  if (!entry) return;
  if (entry.summary) leo.render(entry.summary, summary(tokens));
  if (entry.body) leo.render(entry.body, body(tokens));
}

leo.on("viewOpened", (agent, slot) => {
  if (slot.kind !== "pane") return;
  const entry = slots.get(key(agent)) || {};
  entry[slot.part] = slot;
  slots.set(key(agent), entry);
  renderAll(agent, 0);
});

leo.on("usageChanged", async (agent) => {
  const usage = await leo.agents.usage(agent);
  leo.log("info", "pane-demo:usage " + JSON.stringify(usage));
  renderAll(agent, usage && usage.session ? usage.session.tokens : 0);
});

leo.log("info", "pane-demo:loaded");
