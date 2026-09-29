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

Lane: B-056
  Branch: autopilot-lane/B-056
  Base: b99094c9ecd9e1431b1c380c2b1e0bb1d2f24c09
  State: landed
  Fixes: 1
  Wip: none
- B-056 verify: shots B-056-1..4. Hide→reveal keeps the same tmux client and scrollback; cross-window selection released W1's hidden copy (one fresh client). Reviews: HIGH busy shell in a pooled split killed silently on eviction; MEDIUM untested cross-identity confirm interleaving; MEDIUM isConfirmed bookkeeping; LOWs → fix round 1.
- B-056 done (b9e6ec48a 9d4b8033b b40d3a4bb, merge dc9658ba3): 1636 tests, lint clean. Fix round 1 fixed the HIGH (no pooling of trees with a shell), consolidated confirm, added the superseded-request rule (D-110), per-window close hook, #require'd fixture. Re-review: all 5 hold; MEDIUM divergent agent predicates (latent) and LOW contentVersion pruning folded into B-062. Row highlight in other windows = shared app-wide list selection (pre-existing; B-058 owns per-window on-screen highlight).

Lane: B-057
  Branch: autopilot-lane/B-057
  Base: 126ff4c0ab38a8616ee081a44065cfb45e0681d8
  State: verifying
  Fixes: 0
  Wip: none
