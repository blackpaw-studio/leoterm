import { describe, expect, it } from "vitest";
import { excerptLog, utf8Length } from "../src/pr/logExcerpt";

const numbered = (n: number): string => Array.from({ length: n }, (_, i) => "line " + (i + 1)).join("\n");

describe("excerptLog", () => {
  it("keeps the last 150 of 200 lines", () => {
    const lines = excerptLog(numbered(200)).split("\n");
    expect(lines).toHaveLength(150);
    expect(lines[0]).toBe("line 51");
    expect(lines[149]).toBe("line 200");
  });

  it("caps at 8 KB of UTF-8 by dropping whole lines from the front", () => {
    const row = "ééééééééééééééééééééééééééééééééééééééééééééééé"; // 47 chars, 94 bytes
    const log = Array.from({ length: 150 }, (_, i) => String(1000 + i) + row).join("\n");
    const out = excerptLog(log);
    expect(utf8Length(out)).toBeLessThanOrEqual(8192);
    const lines = out.split("\n");
    expect(lines[lines.length - 1]).toBe("1149" + row);
    expect(lines.every((l) => l.endsWith(row))).toBe(true);
    expect(lines.length).toBeGreaterThan(70);
  });

  it("never cuts inside a code point when one line exceeds the cap", () => {
    const out = excerptLog("🚀".repeat(5000));
    expect(utf8Length(out)).toBeLessThanOrEqual(8192);
    expect(out).toMatch(/^(🚀)+$/u);
    expect(out).not.toContain("�");
    expect(Array.from(out)).toHaveLength(2048);
  });

  it("strips ANSI escapes, leading ISO timestamps and a BOM", () => {
    const log = "﻿2026-11-10T12:00:00.1234567Z \u001b[31;1mError:\u001b[0m boom\n2026-11-10T12:00:01Z plain";
    expect(excerptLog(log)).toBe("Error: boom\nplain");
  });

  it("handles CRLF logs and a trailing newline", () => {
    expect(excerptLog("a\r\nb\r\nc\r\n")).toBe("a\nb\nc");
  });

  it("returns an empty string for an empty log", () => {
    expect(excerptLog("")).toBe("");
  });
});

describe("utf8Length", () => {
  it("counts bytes per code point", () => {
    expect(utf8Length("aé✓🚀")).toBe(1 + 2 + 3 + 4);
  });
});
