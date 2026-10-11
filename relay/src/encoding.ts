const B64URL = /^[A-Za-z0-9_-]*$/;

export const bytesToB64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/**
 * Strict unpadded base64url decode. Null for characters outside the alphabet, an impossible length,
 * or a noncanonical spelling (nonzero unused trailing bits): one byte string, one encoding.
 */
export const b64urlToBytes = (s: string): Uint8Array | null => {
  if (!B64URL.test(s) || s.length % 4 === 1) return null;
  try {
    const bytes = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
    return bytesToB64url(bytes) === s ? bytes : null;
  } catch {
    return null;
  }
};
