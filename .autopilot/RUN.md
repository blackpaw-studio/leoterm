Status: running
Item: B-035
Base: 826e921ee
Wip: none
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged; inbox applied (B-044 stays blocked as Needs Evan to do; B-010 re-scoped → ready; B-013 → ready; B-014 → deferred; D-081..D-084). No vetoes. No BOARD.md, so board off.
- Order this run: B-010 (re-scoped), B-013 (leo request + fixture-built app side), B-012, B-035.
- B-010 done: dfe6f29e8 (1393 tests). Verified B-010-1 (Pinned + activity order), B-010-2 (Name sort). Review clean (pins carry to a namesake: accepted, D-085). D-085.
- B-013: request sent to leo (reply: needs Evan's approval, notes folded into D-086; agreed agents-only v1). App side dispatched (d-c05363bf82ff).
- B-013: leo reports Evan approved the daemon contract (proposal + stat/line/reason/in-memory/agents-only); leo is implementing; no restart; release at Evan's call.
- B-013 built 30fe234bf (1436 tests). Verified B-013-1 (doc·2 indicator on a fixture row, no clicks). review.security: HIGH path/non-regular files (scoped: no workspace confinement, regular files only), HIGH focused tab keyed by name, MED open flood, MED unbounded /state decode → attempt 1 (d-c05363bf82ff#2).
- B-013 attempt 1 3a8b8529d (1452 tests). Re-review: prior MEDs closed; HIGH row-click/refocus bypasses incarnation gate, HIGH SFTP FIFO swap after stat (bounded by timeout, not redesign), MED seen-before-open → attempt 2 (d-c05363bf82ff#3).
- B-013 attempt 2 9483da369 (1463 tests). Re-review 2 dispatched.
- B-013 re-review 2: priors closed (SFTP close is per-access, not the ControlMaster). New MED stale stat replaces newer file → attempt 3 (d-c05363bf82ff#4). LOW dismissed (timeout test uses a fake; transport close fails pending requests by code reading; no remote FIFO fixture).
- B-013 re-review 3: prior MED closed; new MED queued open always dropped (stale counter), MED closed pane reopens. 3 fix attempts used → reverted f3e8d36b3; blocked (drop auto-open?). D-086 reverted; daemon request stands.
- B-012: measured (4 cold launches, 103 agents, local): sidebar at +378–400 ms, list at +500–523 ms (~120 ms spinner); first fetch doesn't block first paint → no cache (no change needed). DEBUG-only LaunchTiming kept: e45d323fb. Review dispatched.
- B-012 review: MED observer never removed, LOW eager detail → attempt 1 826e921ee (1393 tests; list at +517 ms). Re-review dispatched.
- B-012 done: e45d323fb 826e921ee. Re-review clean. D-087.
- B-035 done: verification only (shots B-035-2, -4, -5). Recipe added to verify.md. New: B-045 (ready next run).
