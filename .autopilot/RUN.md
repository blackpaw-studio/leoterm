Status: running
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-09-28: main already merged; inbox empty; no vetoes, answers, or promotions. Vision revised (D-098..D-101): sidebar-navigation milestone.
- Board sync (preflight): B-014: unknown status [deferred]

Lane: B-054
  Branch: autopilot-lane/B-054
  Base: 159c2f7af8910e4071ea836e9e8ece84cf5e8cd2
  State: landed
  Fixes: 0
  Wip: none
- B-054 done (3a2205a65, merge 0ed99778a): 1573 tests, lint clean; review: no CRITICAL/HIGH; LOW real-ssh-in-tests dismissed as pre-existing pattern but filed B-061 (next run) since B-054 adds a template ssh call; LOW comment nit dismissed (comments cover it). Shots B-054-1,-3,-4; the sheet's popup isn't reachable (no AX), covered by tests.

Lane: B-055
  Branch: autopilot-lane/B-055
  Base: 0ca3255cf4ad2126c807e8e243908b2750dc2f0b
  State: landed
  Fixes: 0
  Wip: none
- B-055 done (4134ce4f4 6fb5c8c8d, merge 9a3fe356b): 1593 tests, lint clean. Reviews (general + lifecycle): no CRITICAL/HIGH. Dismissed: MEDIUM per-origin in-flight guard (swaps run on the main actor; the last click wins and the displaced tree is retired/freed, verified one tmux client live); LOW confirm TOCTOU (a process starting in the same run-loop turn; negligible); LOW attachments/isOpen brief disagreement (every caller re-derives from surfaceTree); LOW dealloc-as-proxy test (live check showed one tmux client after switches). Filed B-062 (rename internals, next run).
- Verify note: one ⌘N keypress was sent while Google Chrome was frontmost (it may have opened a Chrome window; Chrome didn't answer AppleEvents to check). Since then every key press activates the debug app by bundle id and checks frontmost first.
