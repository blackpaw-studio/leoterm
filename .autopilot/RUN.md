Status: running
Item: B-010
Base: 78a48118d
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: merged main (263107e9a); inbox empty; the one veto already reverted; B-027's answer already logged. Promoted B-038 B-039 B-040. Added board-state.json to .gitignore. No BOARD.md, so board off.
- Order this run: B-038, B-033 (small visible polish), then B-009, B-010, B-011 (Tier 2 sidebar features). Next run: B-039, B-040, B-035, B-012.
- B-038: built 622783dad (1254 tests). Verified B-038-1 (one-line reason). Choose Agent disabled in AX with help text but still renders full blue → attempt 1 (d-ce062e150574#2).
- B-038 done: 622783dad d1e8e149a (1254 tests). Attempt-1 fix d1e8e149a; verified B-038-1/2. review: 1 LOW dismissed (D-068). New: B-041.
- B-033: built 7dd3ea2bf (1265 tests). Shot B-033-1: short path + Quit/Show in Finder, but the file name hyphenates mid-word ("macos.de-bug") → attempt 1. Alert AX unreachable (see fails: AX tree incomplete), so Show in Finder not driven; covered by unit tests.
- B-033: attempt-1 fix f93fab899 (1267 tests). Verified B-033-2 (path-free sentence, one middle-truncated path line). review: MED (reveal target fixed at open; file removed → selects missing file) + LOW (U+2028/9 and unsanitized tooltip) → attempt 2 (d-ed3d6a77f457#3). LOW dismissed: the test calls the selector directly because the modal loop can't be driven in a unit test.
- B-033 done: 7dd3ea2bf f93fab899 e2736fec7 (1269 tests). Attempt-2 fix e2736fec7; re-review: 1 LOW dismissed (D-070).
- B-009: built 93a8c5b9f 823a717fb (1304 tests; ⌥⌘F since ⌘F is Ghostty's Find). Verified B-009-1 (⌥⌘F + "lha" → leo-home-assistant), B-009-2 (Escape clears), B-009-3 (sidebar hidden → Find Agent shows + focuses; bold "vit").
- B-009 done: 93a8c5b9f 823a717fb 03974e177. review: MED (expanding case folds; names aren't ASCII-only) + LOW (shared defaults suite) → attempt 1 03974e177; re-review clean. D-071, D-072. New: B-042.
