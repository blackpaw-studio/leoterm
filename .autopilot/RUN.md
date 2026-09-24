Status: finished
Item: B-011
Base: eab2d6587
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
- B-010: built c7e629b18 893207531 (1341 tests; last_activity_at from /observe/state, ⌥⌘P). Verified B-010-1 (chevrons, activity order), B-010-2 (context-menu Pin → Pinned section), B-010-3/4 (Stopped collapsed + Name sort survive relaunch). Agents ▸ Pin Agent isn't in peekaboo's menu listing (nor is Reconnect; likely disabled with no selection).
- B-010: review HIGH (all sections collapsed → "No matches", headers gone) + 2 MED (coalescer drops working stamp; state fetch overwrites newer stamps) → attempt 1 (d-7b9d8385046c#2). LOW (future-stamped event) dismissed: state and events share the daemon clock.
- B-010: attempt-1 fix 7135d921d (1345 tests). Verified B-010-5 (all collapsed keeps headers). Re-review MED (activity map never pruned; recreated name inherits state/stamp) → attempt 2 (d-7b9d8385046c#3).
- B-010: attempt-2 fix a2f710afb (1346 tests). Re-review: 2 MED races around the prune (in-flight list drops a new agent's activity; drain after prune lets a namesake inherit) → attempt 3 (d-7b9d8385046c#4): prune keyed on fetch-start sequence.
- B-010 blocked after 3 fix attempts: concurrency re-review of 94cb3a42b found HIGH (stale state fetch applies a deleted agent's activity to a recreated namesake) + MED (SSE recovery keeps lastListedNames, drops a new namesake's activity). Code reverted f6dfc8aec (tree = base). Question asked (re-scope to snapshot-only activity sort).
- B-011: built a8b800d41 (1335 tests; started_at as incarnation id; no tokens/cost or current_action live). Shot B-011-1: times show, but truncate on longer subtitles → attempt 1 (d-00c01ffa3426#2).
- B-011: attempt-1 fix fd679d90a (1337 tests); verified B-011-2 (time never truncates; template squeezes to "clau…" → polish B-043). review.concurrency on a8b800d41: MED (pending refetch never started when baseline returns before flush) → attempt 2 (d-00c01ffa3426#3); LOW dismissed ("working" with no stamp shows no "now"; the Working label already reports it).
- B-011 done: a8b800d41 fd679d90a 8b5808341 (1338 tests). Attempt-2 fix 8b5808341; re-review clean. D-074, D-075. New: B-043.
