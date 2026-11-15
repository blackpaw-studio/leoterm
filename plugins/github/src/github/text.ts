// Dependency-free base64 and UTF-8 decoding: the plugin runtime is a bare JS context
// (no atob, no TextDecoder, no Buffer).

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function base64ToBytes(input: string): number[] {
  const bytes: number[] = [];
  let acc = 0;
  let bits = 0;
  for (const ch of input) {
    const v = B64.indexOf(ch);
    if (v < 0) continue; // padding, whitespace
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((acc >> bits) & 0xff);
    }
  }
  return bytes;
}

/** Lenient UTF-8 decode: malformed sequences become U+FFFD. */
export function utf8ToString(bytes: readonly number[]): string {
  let out = "";
  for (let i = 0; i < bytes.length; ) {
    const b = bytes[i];
    const len = b < 0x80 ? 1 : b >= 0xc2 && b < 0xe0 ? 2 : b >= 0xe0 && b < 0xf0 ? 3 : b >= 0xf0 && b < 0xf5 ? 4 : 0;
    const tail = bytes.slice(i + 1, i + len);
    const valid = len > 0 && tail.length === len - 1 && tail.every((t) => (t & 0xc0) === 0x80);
    if (!valid) {
      out += "�";
      i += 1;
      continue;
    }
    const cp =
      len === 1 ? b : len === 2 ? b & 0x1f : len === 3 ? b & 0x0f : b & 0x07;
    const point = tail.reduce((acc, t) => (acc << 6) | (t & 0x3f), cp);
    const overlongOrInvalid = (len === 3 && point < 0x800) || (len === 4 && (point < 0x10000 || point > 0x10ffff)) || (point >= 0xd800 && point <= 0xdfff);
    out += overlongOrInvalid ? "�" : String.fromCodePoint(point);
    i += len;
  }
  return out;
}
