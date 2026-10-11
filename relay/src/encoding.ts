const B64URL = /^[A-Za-z0-9_-]*$/;

export const bytesToB64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Strict unpadded base64url decode; null on any character outside the alphabet or an impossible length. */
export const b64urlToBytes = (s: string): Uint8Array | null => {
  if (!B64URL.test(s) || s.length % 4 === 1) return null;
  try {
    return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
};
