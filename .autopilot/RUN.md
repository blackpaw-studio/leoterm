Status: running
Item: B-034
Base: ca7f95730951c8839f4bf93e88e89d953e0c8add
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged. Inbox applied: B-027 answered (D-051, ready); GUI input approved (D-052). Promoted B-029 B-030 B-031. Order this run: B-027, B-030, B-031, B-023, B-007.
- B-027: built 10be4b608 6fec65c82 67de1e864 682f967c4 (1162 tests). Verified: shot B-027-1 (a second `open -n` exits; the first stays up and frontmost). 10be4b608/6fec65c82 carry a mistakenly committed 1 MB macos/default.profraw, untracked in 682f967c4 (no history rewrite). review.concurrency: HIGH (lock refusal fails open) + MED (stray XCTest env var skips the lock) → attempt 1 (d-66799406dcfc#2): fail closed with an alert (D-053).
- B-027 done: 10be4b608 6fec65c82 67de1e864 682f967c4 73109b6c3 (1163 tests). Attempt-1 fix 73109b6c3; re-review clean. Verified: B-027-1, B-027-2. New: B-032 (tests leak sockets into the real cache dir), B-033 (alert path).
- B-030: built 31a72e027 (1167 tests). review dispatch failed ("workspace routing discovery timed out") → code-reviewer fallback: 2 should-fix (disk reload keeps a stale full range; clamp can split a surrogate) + NIT (compound edit overwrites the recorded selection) → attempt 1 (d-0c51d8ab2f82#2). Pre-existing undo/IME bypass dismissed (not introduced here). Banner shot blocked: peekaboo can't focus the Open panel (axElementNotFound / focusVerificationTimeout), osascript has no keystroke permission → new B-034 (DEBUG open-file hook).
- B-030: attempt-1 fix 0fd885414 (1170 tests). Re-review: P2 (a record survives a super veto) → attempt 2; the implementer window was gone (paste failed / composer unknown), so cancelled and re-dispatched fresh (d-8e799dea9d4e).
- B-030 done: 31a72e027 0fd885414 ca7f95730 (1171 tests). 3rd review clean. D-055. Not visually verified → B-034.
