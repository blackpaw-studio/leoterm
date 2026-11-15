/** Hard ceiling on any request body, in bytes. Real bodies are under 3.5 KiB. */
export const MAX_BODY_BYTES = 4096;

/**
 * Reads the request body as text without ever buffering more than `maxBytes`.
 * Returns null when the body is over the cap: rejected up front from Content-Length when declared,
 * otherwise by cancelling the stream as soon as the cap is crossed.
 */
export const readBodyCapped = async (req: Request, maxBytes = MAX_BODY_BYTES): Promise<string | null> => {
  const declared = req.headers.get("content-length");
  if (declared !== null && !(Number(declared) <= maxBytes)) {
    await req.body?.cancel().catch(() => {});
    return null;
  }
  if (!req.body) return "";

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
};
