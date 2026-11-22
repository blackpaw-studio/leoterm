import { describe, expect, it } from "vitest";
import manifest from "../leo-plugin.json";
import pkg from "../package.json";

describe("manifest", () => {
  it("needs API v2 for credentials and Meter/Group", () => {
    expect(manifest.apiVersion).toBe(2);
  });

  it("lists each credential kind's bound host in network", () => {
    expect(manifest.permissions.credentials).toEqual(["claude-code", "codex"]);
    expect(manifest.permissions.network).toEqual(expect.arrayContaining(["api.anthropic.com", "chatgpt.com"]));
    expect(manifest.permissions.secrets).toBe(true);
  });

  it("loads dist/main.js, which is built outside macos/", () => {
    expect(manifest.main).toBe("dist/main.js");
    expect(pkg.scripts.build).toContain("--outfile=dist/main.js");
    expect(pkg.scripts.build).not.toContain("macos/");
  });

  it("contributes the sidebar section and the four commands", () => {
    expect(manifest.contributes.sidebarSections).toEqual([{ id: "usage", title: "Usage" }]);
    expect(manifest.contributes.commands.map((c) => c.id)).toEqual(["show", "add-claude", "add-codex", "refresh"]);
  });
});
