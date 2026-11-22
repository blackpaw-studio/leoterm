import { describe, expect, it } from "vitest";
import allowlistSource from "../../../Packages/LeoKit/Sources/LeoKit/Plugins/Slots/LeoPluginSymbolAllowlist.swift?raw";
import manifest from "../leo-plugin.json";
import { createPlugin } from "../src/plugin";
import { CLAUDE_URL, CODEX_URL } from "../src/poller";
import { fullRoot, sidebarRoot } from "../src/views";
import type { Account } from "../src/poller";
import claudeFull from "./fixtures/claude-full.json";
import codexFull from "./fixtures/codex-full.json";
import { createStubLeo } from "./stubLeo";

const body = allowlistSource.slice(allowlistSource.indexOf("names: Set<String> = ["));
const ALLOWED = new Set([...body.matchAll(/"([a-z0-9.]+)"/g)].map((m) => m[1]));

const symbolsIn = (node: unknown, out = new Set<string>()): Set<string> => {
  if (Array.isArray(node)) node.forEach((n) => symbolsIn(n, out));
  else if (typeof node === "object" && node !== null) {
    for (const [k, v] of Object.entries(node)) {
      if (k === "sfSymbol" && typeof v === "string") out.add(v);
      else symbolsIn(v, out);
    }
  }
  return out;
};

const NOW = Date.UTC(2026, 0, 1, 12);
const win = [{ key: "session", label: "Session", percent: 50, resetsAtMs: NOW + 3_600_000 }] as const;
const accountIn = (status: Account["state"]["status"], kind: "claude-code" | "codex"): Account => ({
  handle: { id: status + kind, kind, label: "l", path: "~/p" },
  label: "l",
  state: { status, windows: status === "ok" || status === "stale" ? win : [], updatedAtMs: NOW - 60_000, message: "m" },
});

describe("SF Symbols", () => {
  it("the allowlist parse found the host's list", () => {
    expect(ALLOWED.size).toBeGreaterThan(50);
    expect(ALLOWED.has("checkmark")).toBe(true);
  });

  it("every symbol in every account state's trees is on the host allowlist", () => {
    const statuses = ["loading", "ok", "stale", "expired", "needsAuthorization", "error"] as const;
    const accounts = statuses.flatMap((s) => [accountIn(s, "claude-code"), accountIn(s, "codex")]);
    const used = new Set([...symbolsIn(sidebarRoot(accounts, NOW)), ...symbolsIn(fullRoot(accounts, NOW)), ...symbolsIn(sidebarRoot([], NOW))]);
    expect(used.size).toBeGreaterThan(8);
    expect([...used].filter((s) => !ALLOWED.has(s))).toEqual([]);
  });

  it("every symbol the plugin renders at runtime (notes included) is allowed", async () => {
    const stub = createStubLeo();
    createPlugin(stub.leo, stub.clock);
    const h = { id: "c1", kind: "claude-code", label: "w", path: "~/.w" } as const;
    stub.queueAdd("claude-code", h, null);
    stub.route("GET", CLAUDE_URL, { body: claudeFull });
    stub.route("GET", CODEX_URL, { body: codexFull });
    await stub.emit("activate", { kind: "section", id: "usage" });
    for (const [cmd, slot] of [["show", "show"], ["add-claude", "add-claude"], ["add-claude", "add-claude-2"], ["refresh", "refresh"]] as const) {
      await stub.emit("command", cmd, { kind: "palette", commandID: slot });
    }
    const used = new Set(stub.renders.flatMap((r) => [...symbolsIn(r.tree)]));
    expect(used.size).toBeGreaterThan(3);
    expect([...used].filter((s) => !ALLOWED.has(s))).toEqual([]);
  });

  it("every manifest symbol is allowed", () => {
    const used = symbolsIn(manifest.contributes);
    expect(used.size).toBeGreaterThan(0);
    expect([...used].filter((s) => !ALLOWED.has(s))).toEqual([]);
  });
});
