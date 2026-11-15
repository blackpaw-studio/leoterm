import { describe, expect, it } from "vitest";
import { ACCESSORY_ID, COMMANDS, PLUGIN_ID, SECTION_ID, VIEW_ID } from "../src/config";
import manifest from "../../../macos/Bundled/Plugins/studio.blackpaw.github/leo-plugin.json";

describe("shipped manifest", () => {
  it("matches the contribution ids the code uses", () => {
    expect(manifest.id).toBe(PLUGIN_ID);
    expect(manifest.main).toBe("main.js");
    expect(manifest.contributes.views.map((v) => v.id)).toEqual([VIEW_ID]);
    expect(manifest.contributes.rowAccessories.map((a) => a.id)).toEqual([ACCESSORY_ID]);
    expect(manifest.contributes.sidebarSections.map((s) => s.id)).toEqual([SECTION_ID]);
    expect(manifest.contributes.commands.map((c) => c.id).sort()).toEqual(Object.values(COMMANDS).sort());
  });
});
