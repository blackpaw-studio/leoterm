import { utf8Length } from "../issues/utf8";

export { utf8Length };
export const MAX_EXCERPT_LINES = 150;
export const MAX_EXCERPT_BYTES = 8 * 1024;

const ANSI = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;
const BOM = /^﻿/;

const codePointBytes = (cp: number): number => (cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4);

/** The longest suffix of `text` within `maxBytes`, starting on a code point boundary. */
function tailWithin(text: string, maxBytes: number): string {
  const points = Array.from(text);
  let bytes = 0;
  let start = points.length;
  while (start > 0) {
    const next = codePointBytes(points[start - 1].codePointAt(0) ?? 0);
    if (bytes + next > maxBytes) break;
    bytes += next;
    start -= 1;
  }
  return points.slice(start).join("");
}

const clean = (line: string): string => line.replace(BOM, "").replace(ANSI, "").replace(TIMESTAMP, "");

/**
 * The tail of a CI job log for an agent: last `maxLines` lines with ANSI escapes and
 * leading timestamps removed, then whole lines dropped from the front until it fits
 * `maxBytes` of UTF-8. A single oversized line is cut from its start on a code point boundary.
 */
export function excerptLog(log: string, maxLines = MAX_EXCERPT_LINES, maxBytes = MAX_EXCERPT_BYTES): string {
  const all = log.split(/\r?\n/);
  if (all[all.length - 1] === "") all.pop();
  // Clean only the lines we keep: logs can be megabytes.
  const lines = all.slice(-maxLines).map(clean);
  const sizes = lines.map((l) => utf8Length(l) + 1);
  let total = sizes.reduce((a, b) => a + b, 0) - 1;
  let first = 0;
  while (total > maxBytes && first < lines.length - 1) {
    total -= sizes[first];
    first += 1;
  }
  const out = lines.slice(first).join("\n");
  return utf8Length(out) > maxBytes ? tailWithin(out, maxBytes) : out;
}
