Status: running
Item: B-007
Base: 0b4d6b506a59a2da7c9bb182d8888ded1ccf248f
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged; inbox empty; no vetoes or answers. Order this run: B-007, B-037, B-032, B-036, B-029 (user-facing milestone gaps first, then test hygiene, then the cleaner hardening).
- B-007: built 7a2bf5da5 (1231 tests). Verified: B-007-1 (LEO_FORCE_DISCONNECTED: banner + dimmed rows), B-007-2 (Agents ▸ Reconnect ⇧⌘R restores rows and badges). Polish seen: the banner's reason wraps mid-word in the narrow sidebar. review.concurrency: HIGH (stale phase after Retry) + 2 MED (stale wake check; palette unsanitized) → attempt 1 (d-7b7d11d7e8bf#2).
