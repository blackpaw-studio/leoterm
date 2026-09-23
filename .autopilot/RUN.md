Status: running
Item: B-019
Base: a365e74530260b39d76766f680ffa3b1f88ab350
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: merged main (ff to 2cc6f5f75). No inbox, vetoes, or answers. Promoted B-019 B-020 B-021 B-022. Order this run: B-005 (milestone), B-022, B-020, B-021, B-019.
- B-005: built 864a16bc6 7204dd557 a2620137c (1059 tests). Verified: shots B-005-1..4 on autopilot-scratch (row menu ▸ Browse Files; arrows and → expand; Return opens Greeter.swift highlighted; ⇧⌘. shows .hidden-config). review.security: 2 HIGH (open race, terminal squeezed to 97 pt), 1 MED (stuck Loading… after reload), 3 LOW; all sent back (attempt 1) to d-8b91dd3084d6. D-036 made for the width.
- B-005 done: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083 (1069 tests). Re-review clean (6/6 fixed); 2 LOWs → B-023 with the dimmed-dotfile polish. Shot B-005-5 confirms the sidebar collapses at 800 pt.
- B-022: built 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c (1086 tests). Verified: shot B-022-1 (1400 pt: editor opens at half the width it shares with the terminal). The hung-save banner can't be driven without a hung remote save → not visually verified. review.concurrency: 2 MED (earlier clean entry edited mid-quit is lost; ⌘W on the stuck editor cancels the logout) + 3 LOW; all sent back (attempt 1) to d-88cbd4249530.
- B-022: attempt-1 fixes 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 (1091 tests). Re-review: 5/5 fixed; new MED (pre-existing: logout hangs forever when the document queue is hung and the user picks Don't Save) + LOW test gap → attempt 2 (d-88cbd4249530#3). Flake seen once: LeoSidebarFeedActivityCoalescingTests.
- B-022: attempt-2 fixes 9865e60b3 b9dd6e318 (1093 tests). 3rd review: both fixed; new MED (drain only covers the tail at call time) + LOW-MED (typing during the wait lost → read-only) + LOW test timing → attempt 3 (d-88cbd4249530#4), the last.
- B-022 done: 14 commits 59ffb1fbd..bbcf58601 (1095 tests). 4th review: all fixed, only LOWs → B-024. Load flakes → B-025.
- B-020: built ad0807785 (1113 tests; timing flakes under load: LeoSyntaxHighlighterAdversarialTests, LeoProcessRunnerTests/timeoutEscalatesToSIGKILL → add to B-025). Error text only → not visually verified. review.security dispatched.
- B-020: review.security dispatch failed (codex/gpt-6-sol: model metadata not found) → code-reviewer fallback. 1 HIGH (tag smuggling) + 1 MED (foreign errors not isolated) → attempt 1 (d-179092105250#2); D-040.
- B-020: attempt-1 fix 796b0a2ec (1114 tests). review.security dispatch failed again (same codex error) → fallback re-review: both fixed; new HIGH (variation-selector smuggling) + MED (blank fillers) → attempt 2 (d-179092105250#3); D-041.
- B-020: attempt-2 fix 8b6494d45 (1117 tests). Fresh fallback review: 2 HIGH (CGJ, uncapped ZWJ/ZWNJ) → attempt 3 (d-179092105250#4), switching to an allowlist (D-042).
- B-020 done: ad0807785 796b0a2ec 8b6494d45 935b5a600 (1122 tests). 3 fix rounds; final review HIGH (selectors after any base) → B-026; kept per D-043.
- B-021: built cda6610e8 (1130 tests). No UI → not visually verified. review.security via code-reviewer fallback (codex route broken all run).
- B-021 done: cda6610e8 (1130 tests). Review: 1 MED dismissed (pre-existing unlink; D-044) → B-027.
- B-019: built c92565ac3 ad537d10e (1132 tests). Test-only → not visually verified. review: HIGH (100 ms sleep can miss a delayed bypass) + MED (fixed sleeps in the recorder) → attempt 1 (d-43d5f92b0d93#2). Note: plain review role routed to codex fine; only review.security failed.
- B-019: attempt-1 fix 79d5d9375 (1132 tests). Re-review: relay test OK; host test P1 (swapped order hangs, not fails) + P2 (50-poll setup) → attempt 2 (d-43d5f92b0d93#3).
- B-019: attempt-2 fix 6be661a48. Re-review: HIGH (no main-queue barrier before the final count) + MED (5 s deadline under load) → attempt 3 (d-43d5f92b0d93#4), the last.
