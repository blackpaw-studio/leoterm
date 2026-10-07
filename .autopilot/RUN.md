Status: running
Started: 2026-10-07T16:40:34Z
Budget: 20 items, until 2026-10-08T04:40:34Z
Digested-through: 0
Focus: leo PR #226 bridge features (B-257–B-262, then B-051)
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-143
  Branch: autopilot-lane/B-143
  Base: e23c0aa4232d0c0a670565289661884195ffae3e
  Tier: full
  State: held
  Fixes: 0
  Wip: a3fe1df0d
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-257
  Branch: autopilot-lane/B-257
  Base: 77e6c369d45f811c845c452353e322f0b82df0a1
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: f3371acc7fa8456db63f9ae389c063b41127380c
  Dispatched: 2026-10-07T16:43:28Z
  Call: Children disappear as soon as the daemon reports a terminal status or ended_at, with no 60 s linger — principle 2
  Call: A child row shows name (falling back to role, then "Dispatch") plus a status word; Stalled is plain secondary text with no badge — principle 2
  Call: Child rows can't be selected (no tag, plus selectionDisabled on macOS 14+), and there are no new shortcuts — principles 1 and 6
  Call: Nothing renders without the hello `dispatch_tree` feature or while disconnected; the parent badge stays purely the daemon's attention.state, and `outstanding` isn't decoded — principle 2
  Call: Disconnect clears records but keeps same-boot ended ids, a boot change clears all, a host switch resets, and a Retry baseline repairs anything missed — principle 5
  Call: Caps that only bound a misbehaving daemon: 256 ended ids, 1024 live records, nesting depth 16, indent clamped at depth 4; only nesting changes emit — principle 2

## Progress
