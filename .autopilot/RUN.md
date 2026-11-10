Status: running
Started: 2026-11-10T01:47:19Z
Budget: 20 items, until 2026-11-10T13:47:19Z
Digested-through: 0
Filed: 0/3 bugs, 0/5 ideas
Untracked-left: default.profraw scratchpad/

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
  Tokens: 60.9M in (60.1M cache read), ≥192k out, 352 requests
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-368
  Branch: autopilot-lane/B-368
  Base: 1ff28347079270c7808348d616101f3a02af1b3f
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: db21be5522415001de8cbb8c988831524c2f577c
  Dispatched: 2026-11-10T01:50:37Z
  Call: Mac only (macos/ test code, no iOS counterpart) — AGENTS.md parity rule
  Call: Test-helper flake fix — AUTONOMY "agent decides"
  Tokens: 12.1M in (11.8M cache read), ≥47.5k out, 125 requests

Lane: B-375
  Branch: autopilot-lane/B-375
  Base: 1ff28347079270c7808348d616101f3a02af1b3f
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T01:50:37Z
  Tokens: 9.34M in (9.13M cache read), ≥26.7k out, 83 requests

Lane: B-378
  Branch: autopilot-lane/B-378
  Base: 2e7ae40c70b8de8ac3c9fdcdb20136ca8f4e4e91
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 19b5732d15421f055effb5d1c1dbb698dbfcea7f
  Dispatched: 2026-11-10T02:19:17Z
  Call: Fix the retained-view bug in product code, not just the test's wait — AUTONOMY "bug fixes, flake fixes"
  Call: Mac only (Ghostty surface code in macos/, iOS has no equivalent) — AGENTS.md parity rule
  Tokens: 14M in (13.7M cache read), ≥55.4k out, 137 requests

Lane: B-379
  Branch: autopilot-lane/B-379
  Base: 9e8da8e038bf5150f1a3e3d14795dc60e8a5e0db
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T03:13:55Z

Lane: B-381
  Branch: autopilot-lane/B-381
  Base: 689016d00e53281e25a5bb0dcedf0f0b2ae0b28d
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-375 blocked
Finished 2: B-368 landed e5c13d879 · not visually verified
Finished 3: B-378 landed 9547eaa11 · not visually verified

Progress:
- Preflight: fast-forwarded main 3e0157f89 into autopilot.
- Inbox applied: created B-378, B-379, B-380 (bugs), B-381 (feature).
- Picked B-368 and B-375 in parallel (independent: a sidebar-resize test vs the toolbar Tasks popover).
- Runners: B-368 d-8cd585787fee, B-375 d-a74d172f9b82 (leo implement role).
- B-375 blocked: couldn't reproduce (test through stub daemon passed). Suspects: popover first-click swallowed (never key window); daemon 409 on source:auto tasks swallowed by dismissTask. Test patch /tmp/b375-dismiss-test.patch.
- Board sync: B-378 --item sync exited 1 once (stderr not captured); retry succeeded.
- B-378 runner d-02ac03fa87fd, parallel with B-368 (different test files).
- B-368 landed e5c13d879 (test helper waits through main-thread stalls; 5/6 pre-fix fails → 20/20 passes). Verifier saw two other load flakes outside the diff: LeoSettingsWindowCloseTests/discardingBothClosesTheWindowAndDropsThePaneEdits, and a host crash rc=5 in aHungMachineDoesNotDelayAnother.
- B-379 runner d-9acab79d2518, parallel with B-378 (different test files).
- B-378 landed 9547eaa11: Ghostty.moveFocus retries held the hidden surface strongly (~0.8 s); now weak captures. Test waits run-loop turns instead of 3 s wall clock.
- B-381 built before B-380 (B-381 redefines the spin behavior B-380 reports; overlapping footprint).
