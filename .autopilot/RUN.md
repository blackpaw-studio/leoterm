Status: running
Item: B-030
Base: 73109b6c38c8061d151ffbe29ad683d3bf7e1797
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged. Inbox applied: B-027 answered (D-051, ready); GUI input approved (D-052). Promoted B-029 B-030 B-031. Order this run: B-027, B-030, B-031, B-023, B-007.
- B-027: built 10be4b608 6fec65c82 67de1e864 682f967c4 (1162 tests). Verified: shot B-027-1 (a second `open -n` exits; the first stays up and frontmost). 10be4b608/6fec65c82 carry a mistakenly committed 1 MB macos/default.profraw, untracked in 682f967c4 (no history rewrite). review.concurrency: HIGH (lock refusal fails open) + MED (stray XCTest env var skips the lock) → attempt 1 (d-66799406dcfc#2): fail closed with an alert (D-053).
- B-027 done: 10be4b608 6fec65c82 67de1e864 682f967c4 73109b6c3 (1163 tests). Attempt-1 fix 73109b6c3; re-review clean. Verified: B-027-1, B-027-2. New: B-032 (tests leak sockets into the real cache dir), B-033 (alert path).
