import { describe, expect, it } from "vitest";
import { PANE_ID } from "../src/plugin";
import manifest from "../../../macos/Bundled/Plugins/studio.blackpaw.status/leo-plugin.json";

describe("shipped manifest", () => {
  it("declares exactly the permissions the plugin needs", () => {
    expect(manifest.permissions).toEqual({ agents: ["read", "usage"] });
  });

  it("contributes the one pane the code renders into", () => {
    expect(manifest.id).toBe("studio.blackpaw.status");
    expect(manifest.main).toBe("main.js");
    expect(manifest.contributes).toEqual({ panes: [{ id: PANE_ID, title: "Status", sfSymbol: "gauge" }] });
  });
});
