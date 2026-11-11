# Recorded GitHub responses

Real responses from the private scratch repo `blackpaw-studio/leo-github-plugin-scratch` (PR #1 on
`feat/sample`: a passing `lint`, a failing `test`, one unresolved review thread), recorded 2026-11-11 with
`gh api -i` / `curl -i`. Only these headers are kept: `etag`, `x-ratelimit-*`, `retry-after`, `location`,
`content-range`, `content-type`, `accept-ranges`. Bodies are scrubbed: logins, display names, emails, node ids,
cursors and avatar URLs are neutral placeholders (`scratch-user`, `PRRT_scratch1`, `cursor-1`). No tokens.

- `pulls-open`, `check-runs`, `status`, `review-threads` (GraphQL), `304` (a conditional re-request with the
  recorded ETag). `../401.json` (an invalid token) and `../pulls-empty.json` are recorded the same way and
  replace the earlier doc-shaped files.
- `job-log-whole`: the 3 KB log of the failing job, as the log host sends it (200, BOM and CRLF intact).
- `job-log-206-probe` / `job-log-206-tail`: `Range: bytes=0-0` and `bytes=511000-` against a 512 KB log. The
  log host (`*.blob.core.windows.net`) honours `bytes=N-` and `bytes=a-b` with 206 + `Content-Range`, but
  answers a suffix range (`bytes=-65536`) with a 200 and the whole body. That is why the plugin probes first.

The redirect from `api.github.com/.../logs` is a 302 to `productionresultssa<N>.blob.core.windows.net`, which the
manifest's `*.blob.core.windows.net` covers.
