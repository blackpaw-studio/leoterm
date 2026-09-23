Status: running
Item: B-027
Base: 30ff402039d35961d95a2d1a3675e442bd5ee128
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged. Inbox applied: B-027 answered (D-051, ready); GUI input approved (D-052). Promoted B-029 B-030 B-031. Order this run: B-027, B-030, B-031, B-023, B-007.
- B-027: built 10be4b608 6fec65c82 67de1e864 682f967c4 (1162 tests). Verified: shot B-027-1 (a second `open -n` exits; the first stays up and frontmost). 10be4b608/6fec65c82 carry a mistakenly committed 1 MB macos/default.profraw, untracked in 682f967c4 (no history rewrite). review.concurrency: HIGH (lock refusal fails open) + MED (stray XCTest env var skips the lock) → attempt 1 (d-66799406dcfc#2): fail closed with an alert (D-053).
