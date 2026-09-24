Status: running
Item: B-037
Base: 8e4f9041b9f4095a7a68888ddfa7954d88e29b3a
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged; inbox empty; no vetoes or answers. Order this run: B-007, B-037, B-032, B-036, B-029 (user-facing milestone gaps first, then test hygiene, then the cleaner hardening).
- B-007: built 7a2bf5da5 (1231 tests). Verified: B-007-1 (LEO_FORCE_DISCONNECTED: banner + dimmed rows), B-007-2 (Agents ▸ Reconnect ⇧⌘R restores rows and badges). Polish seen: the banner's reason wraps mid-word in the narrow sidebar. review.concurrency: HIGH (stale phase after Retry) + 2 MED (stale wake check; palette unsanitized) → attempt 1 (d-7b7d11d7e8bf#2).
- B-007: attempt-1 fix 4f1cd16b7 (1235 tests). Re-review: HIGH (late `.connected` after `.failed` in one generation) + MED (sidebar `.failed` panel unsanitized) → attempt 2 (d-7b7d11d7e8bf#3). LOW dismissed: the wake-token test drives the token check directly because actor arrival order can't be forced in a test.
- B-007 done: 7a2bf5da5 4f1cd16b7 0ed8a6b8f (1237 tests). Attempt-2 fix 0ed8a6b8f; 3rd review clean. D-061, D-062. Verified B-007-1/2. New: B-038.
- B-037: built 9307c661c (1239 tests). Verified: B-037-1/2/3 (1400 → 700 → 1400 single jumps; sidebar and editor both return). review dispatch failed ("workspace routing discovery timed out") → code-reviewer fallback.
