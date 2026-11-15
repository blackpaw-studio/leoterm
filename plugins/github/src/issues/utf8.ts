/** UTF-8 size of one code point (no TextEncoder in the plugin runtime). */
const codePointBytes = (ch: string): number => {
  const cp = ch.codePointAt(0) ?? 0;
  return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
};

export const utf8Length = (s: string): number => {
  let n = 0;
  for (const ch of s) n += codePointBytes(ch);
  return n;
};

/** Longest prefix within `maxBytes` of UTF-8, never splitting a code point. */
export const truncateUtf8 = (s: string, maxBytes: number): string => {
  let bytes = 0;
  let end = 0;
  for (const ch of s) {
    bytes += codePointBytes(ch);
    if (bytes > maxBytes) break;
    end += ch.length;
  }
  return s.slice(0, end);
};
