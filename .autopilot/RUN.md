Status: running
Item: B-015
Base: 7603c68e5f2570aed60a6bf377520b2de30bf54b
Wip: none

## Progress
- Preflight clean (untracked verify prereqs left: macos/default.profraw, scratchpad/, zig-out symlink). No inbox, vetoes, or answers. Promoted B-015, B-016, B-017.
- B-015: built c5c24c336 8dfe3aa7c 91fd60791 (854 tests). Logic-only, no visual change → not visually verified. review.concurrency 1 HIGH/2 MED/2 LOW; LOW (e)-test-only dismissed; rest sent back (attempt 1) to d-01d37c8188e4 (first implementer window died).
- B-015: attempt-1 fix 4fea50a28 (862 tests). Re-review agreed HIGH unreachable (tests pin it); new MED (over-broad drop in recovery) + LOW (tombstone trim hits live resets) sent back (attempt 2) to d-3567d9ba6461; LOW retain-over-keeps dismissed (self-heals next list).
