Status: running
Item: B-022
Base: 860df8083ada19da7fd179bb95da485c2426070c
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: merged main (ff to 2cc6f5f75). No inbox, vetoes, or answers. Promoted B-019 B-020 B-021 B-022. Order this run: B-005 (milestone), B-022, B-020, B-021, B-019.
- B-005: built 864a16bc6 7204dd557 a2620137c (1059 tests). Verified: shots B-005-1..4 on autopilot-scratch (row menu ▸ Browse Files; arrows and → expand; Return opens Greeter.swift highlighted; ⇧⌘. shows .hidden-config). review.security: 2 HIGH (open race, terminal squeezed to 97 pt), 1 MED (stuck Loading… after reload), 3 LOW; all sent back (attempt 1) to d-8b91dd3084d6. D-036 made for the width.
- B-005 done: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083 (1069 tests). Re-review clean (6/6 fixed); 2 LOWs → B-023 with the dimmed-dotfile polish. Shot B-005-5 confirms the sidebar collapses at 800 pt.
- B-022: built 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c (1086 tests). Verified: shot B-022-1 (1400 pt: editor opens at half the width it shares with the terminal). The hung-save banner can't be driven without a hung remote save → not visually verified. review.concurrency: 2 MED (earlier clean entry edited mid-quit is lost; ⌘W on the stuck editor cancels the logout) + 3 LOW; all sent back (attempt 1) to d-88cbd4249530.
- B-022: attempt-1 fixes 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 (1091 tests). Re-review: 5/5 fixed; new MED (pre-existing: logout hangs forever when the document queue is hung and the user picks Don't Save) + LOW test gap → attempt 2 (d-88cbd4249530#3). Flake seen once: LeoSidebarFeedActivityCoalescingTests.
