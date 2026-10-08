Status: running
Started: 2026-10-08T21:26:35Z
Budget: 20 items, until 2026-10-09T09:26:35Z
Digested-through: 0
Filed: 1/3 bugs, 0/5 ideas
Self-filed: B-235 → B-269 bug — Invalid UTF-8 SFTP stderr hides the missing-server message
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

Lane: B-051
  Branch: autopilot-lane/B-051
  Base: 383cbe02a346fc0067fa8e8e3bd3525c9e70cd95
  Tier: full
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-08T21:30:07Z
  Call: Don't decode `outstanding` or add a subtitle count — D-377, VISION 2 "never invent a state"
  Call: No app commits on the daemon-side branch (existing LeoDispatchHoldIntegrationTests already guard that the app mirrors a held `working`) — AUTONOMY test infra
  Call: Used existing `autopilot-scratch` (not deleted, stopped afterwards) — AUTONOMY real-agent rule

Lane: B-235
  Branch: autopilot-lane/B-235
  Base: 65980700657bc5474aa0c3ccaba981d2f185e956
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 34f10e0eeb952ad3d8332959c3a13ec94baf0885
  Dispatched: 2026-10-08T21:43:23Z
  Call: Each stderr line is judged independently at byte level, and the canonical line must be exact ASCII — AUTONOMY: bug fix, parse untrusted server stderr conservatively
  Call: Strip exactly one trailing CR, so a CRLF-terminated canonical line now matches — AUTONOMY: bug fix
  Call: Leave the stderr `detail` decoding (`<N bytes>`) and the status-127 marker path unchanged — AUTONOMY: scope
  Call: Lane-local GhosttyKit.xcframework and zig-out symlinks added to `info/exclude` — AUTONOMY: test infra

## Progress
- B-051 runner dispatched (leo implement d-33d34a2ad44e, pane ap-B-051) at 2026-10-08T21:30:07Z.
- B-051 blocked: root cause daemon-side (turn.complete ignores pending.tasks; ~89 s Finished while a background Bash ran). Spec + trace in .autopilot/bugs/B-051/. Shelved on autopilot-shelved/B-051 (no commits).
Finished 1: B-051 blocked
- B-235 landed 12530adbb: SFTP subsystem-rejection matched on raw stderr bytes per line (exact ASCII, one trailing CR stripped); regression test with invalid UTF-8 suffix; suite 2341 green (1 unrelated focus flake on first run); not visually verified (needs a remote host). Self-filed bug B-269.
Finished 2: B-235 landed 12530adbba7841dc125adc556417297c532f7899 · not visually verified
