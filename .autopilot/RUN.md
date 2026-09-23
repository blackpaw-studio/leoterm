Status: running
Item: B-016
Base: f2ed8537acb7b23f8c33935f78fe8c96e82c8385
Wip: none

## Progress
- Preflight clean (untracked verify prereqs left: macos/default.profraw, scratchpad/, zig-out symlink). No inbox, vetoes, or answers. Promoted B-015, B-016, B-017.
- B-015: built c5c24c336 8dfe3aa7c 91fd60791 (854 tests). Logic-only, no visual change → not visually verified. review.concurrency 1 HIGH/2 MED/2 LOW; LOW (e)-test-only dismissed; rest sent back (attempt 1) to d-01d37c8188e4 (first implementer window died).
- B-015: attempt-1 fix 4fea50a28 (862 tests). Re-review agreed HIGH unreachable (tests pin it); new MED (over-broad drop in recovery) + LOW (tombstone trim hits live resets) sent back (attempt 2) to d-3567d9ba6461; LOW retain-over-keeps dismissed (self-heals next list).
- B-015 done: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e (866 tests, only the known failure). 3rd review MED (pre-existing recreate edge) + 2 LOW → B-018, blocked on the leo instance-id contract (D-027). Not visually verified (logic only).
- B-018 done: f2ed8537a (858 tests). Review clean; 3 LOW dismissed (D-028). Not visually verified (logic only).
- B-016: built c25cf3523 82c835016 ab3f8c6ff 7d2b676e7 (864 tests). Visual: shot B-016-1.png shows hovered "artist-c…" truncating before Attach (b OK). Review: 2 MED (sidebar focus = not viewing for attention/Jump; unordered focus Tasks) + 3 LOW, all sent back (attempt 1) to d-6ae4aec308d6.
