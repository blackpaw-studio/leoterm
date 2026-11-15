import "../../leo.d.ts";
import { callback, copy } from "../../actions";

leo.on("viewOpened", async (agent, slot) => {
  leo.render(slot, { type: "Loading", message: "Loading…" });
  const agents = await leo.agents.list();
  const mine = agents.find((a) => a.name === agent.name && a.machine === agent.machine);
  const subtitle = mine ? mine.status + " · " + (mine.branch ?? "no branch") : "unknown";
  leo.render(slot, {
    type: "List",
    sections: [{
      items: [{
        id: "status",
        title: agent.name,
        subtitle,
        sfSymbol: "person.crop.circle",
        actions: [callback("refresh"), copy(agent.name)],
      }],
    }],
  });
});

leo.on("callback", (id) => {
  leo.log("info", "callback " + id);
});
