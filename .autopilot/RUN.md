Status: finished
Item: B-004
Base: abf708a5402fdeef36153ae126348419011ee700
Wip: none

## Progress
- Preflight clean (untracked verify prereqs left: macos/default.profraw, scratchpad/, zig-out symlink). No inbox, vetoes, or answers. Promoted B-015, B-016, B-017.
- B-015: built c5c24c336 8dfe3aa7c 91fd60791 (854 tests). Logic-only, no visual change → not visually verified. review.concurrency 1 HIGH/2 MED/2 LOW; LOW (e)-test-only dismissed; rest sent back (attempt 1) to d-01d37c8188e4 (first implementer window died).
- B-015: attempt-1 fix 4fea50a28 (862 tests). Re-review agreed HIGH unreachable (tests pin it); new MED (over-broad drop in recovery) + LOW (tombstone trim hits live resets) sent back (attempt 2) to d-3567d9ba6461; LOW retain-over-keeps dismissed (self-heals next list).
- B-015 done: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e (866 tests, only the known failure). 3rd review MED (pre-existing recreate edge) + 2 LOW → B-018, blocked on the leo instance-id contract (D-027). Not visually verified (logic only).
- B-018 done: f2ed8537a (858 tests). Review clean; 3 LOW dismissed (D-028). Not visually verified (logic only).
- B-016: built c25cf3523 82c835016 ab3f8c6ff 7d2b676e7 (864 tests). Visual: shot B-016-1.png shows hovered "artist-c…" truncating before Attach (b OK). Review: 2 MED (sidebar focus = not viewing for attention/Jump; unordered focus Tasks) + 3 LOW, all sent back (attempt 1) to d-6ae4aec308d6.
- B-016 done: 7 commits (867 tests). Re-review clean; 2 LOW test gaps → B-019 (ready next run); tab-reuse-on-view logged in D-029.
- B-017: built 97781e299 f8b3b4350 fb1bb244b (885 tests). No UI → not visually verified. review.security: 1 MED (unsanitized server text) + 3 LOW, all sent back (attempt 1) to d-6d532cbdbef3. Implementer flagged: forwarded daemon socket in ~/.leo/state/leoterm still breaks for long homes → new item.
- B-017: attempt-1 fixes 119697892 198da68e3 adb143d49 (898 tests). Re-review: only LOWs (Mn flood, filenames unsanitized, quote lookalikes, ZWJ, tests) → sent back (attempt 2) to d-30f1e7df9737.
- B-017 done: 9 commits (908 tests). 3 fix rounds; 3rd security review MEDs are B-003-era raw paths → B-020 (D-032); daemon socket budget → B-021. Not visually verified (no UI).
- B-004: built 10 commits 5980d43a6..9db8771af (993 tests). Launch-alive OK. Verified: shot B-004-1.png (Open File in Editor → highlighted Swift in trailing split; opens at 320pt min, 50/50 not done). review.security: 3 HIGH (col overflow crash, ReDoS md/yaml, close-tab loses edits) + 3 MED + 4 LOW; all but file://-host LOW sent back (attempt 1) to d-43c58450cc31. A system Screen Recording prompt for "leo" was on screen; left untouched.
- B-004: attempt-1 fixes a820ef868..eca4cfbc1 (1016 tests, launch alive). Re-review: 2 MED (edit lost during silent reload; hung SFTP blocks quit) + LOW terminateLater + LOW quit-review release → attempt 2 (d-43c58450cc31#3). LOW controller-wiring tests → next run.
- B-004: attempt-2 fixes a0f19db31 5cd057694 (1025 tests, launch alive). Re-review: HIGH (Quit Anyway on system quit/quit-review skips other dirty editors) + LOW sheet window → attempt 3 (d-43c58450cc31#4). MED logout+hung-save needs laptop check → next run.
- B-004 done: 19 commits (1027 tests). 3 fix rounds; final MED + gaps → B-022; kept despite 3-attempt rule (D-034). Run finished: cap of 5 reached.
