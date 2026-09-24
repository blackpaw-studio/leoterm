Status: running
Item: B-036
Base: 5f229190b
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged; inbox empty; no vetoes or answers. Order this run: B-007, B-037, B-032, B-036, B-029 (user-facing milestone gaps first, then test hygiene, then the cleaner hardening).
- B-007: built 7a2bf5da5 (1231 tests). Verified: B-007-1 (LEO_FORCE_DISCONNECTED: banner + dimmed rows), B-007-2 (Agents ▸ Reconnect ⇧⌘R restores rows and badges). Polish seen: the banner's reason wraps mid-word in the narrow sidebar. review.concurrency: HIGH (stale phase after Retry) + 2 MED (stale wake check; palette unsanitized) → attempt 1 (d-7b7d11d7e8bf#2).
- B-007: attempt-1 fix 4f1cd16b7 (1235 tests). Re-review: HIGH (late `.connected` after `.failed` in one generation) + MED (sidebar `.failed` panel unsanitized) → attempt 2 (d-7b7d11d7e8bf#3). LOW dismissed: the wake-token test drives the token check directly because actor arrival order can't be forced in a test.
- B-007 done: 7a2bf5da5 4f1cd16b7 0ed8a6b8f (1237 tests). Attempt-2 fix 0ed8a6b8f; 3rd review clean. D-061, D-062. Verified B-007-1/2. New: B-038.
- B-037: built 9307c661c (1239 tests). Verified: B-037-1/2/3 (1400 → 700 → 1400 single jumps; sidebar and editor both return). review dispatch failed ("workspace routing discovery timed out") → code-reviewer fallback.
- B-037 done: 9307c661c (1239 tests). Review (Sonnet fallback) clean; 2 LOW dismissed (D-063). Verified B-037-1/2/3.
- B-032: built f6a591e0a 41a653cfd (1239 tests). Test-only. review: HIGH dismissed (the guard caught the real leak in run b032red, so bundle callbacks fire for Swift Testing) + MED (shared permanent /tmp dir) → attempt 1 (d-1d6b71d11dd5#2).
- B-032: attempt-1 fix aeb23c6b5 (1241 tests; guard timing confirmed: start snapshot precedes Swift Testing's run start). Re-review: MED (per-process dir not reserved exclusively; cleanup could remove another run's dir) → attempt 2 (d-1d6b71d11dd5#3).
- B-032 done: f6a591e0a 41a653cfd aeb23c6b5 b03191132 (1244 tests). Attempt-2 fix b03191132; 3rd review MED dismissed (D-064). Test-only.
