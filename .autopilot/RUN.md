Status: running
Started: 2026-11-26T00:49:37Z
Budget: 20 items, until 2026-11-26T12:49:37Z
Digested-through: 0
Filed: 1/3 bugs, 2/5 ideas
Self-filed: B-453 → B-461 bug — resetWindowSizeRestoresALaunchClampedSidebar fails (200 vs 199) on autopilot
Self-filed: B-454 → dropped (dup of B-455) — Handoff banner ignores Return while caps lock is on
Self-filed: B-447 → dropped (dup of B-461) — resetWindowSizeRestoresALaunchClampedSidebar fails
Self-filed: B-447 → B-462 idea — Row/Rows suites run slower on each repeat in one process
Self-filed: B-447 → B-463 idea — leo-runtests.sh skips 129 host-tier suites (no TEST_RUNNER_LEO_HOST_TESTS=1)
Untracked-left: default.profraw scratchpad/
Note: B-445 closed at preflight — owner answered "accept your recommendation (close)".

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-447
  Branch: autopilot-lane/B-447
  Base: a7729797ae03c3d14c5e2da4fb6d79b9cc980774
  Tier: light→full
  State: landed
  Fixes: 1
  Wip: none
  Dispatched: 2026-11-26T00:52:06Z
  Reverifies: 0
  Reviewed-tip: 6d82a5f2d8333a56e8dbdb2ac12e1d87ab665b82
  Call: Fix in product `Ghostty.moveFocus`, not the test fixtures; the first plan's premise (fixture windows never get a display cycle) was disproved at step 0 — AUTONOMY: bug/flake fixes are the agent's call
  Call: Newest landed move wins per window, decided when the retry lands; retry delays stay 50/100/200/400 ms — Engineering: fix flakes at the cause
  Call: A window is stamped only when makeFirstResponder succeeds, so a refused move doesn't block older retries — smallest rule that keeps chat routing as it was
  Call: Dropped `heavy` around the verify-lock wait, kept it around xcodebuild (its idle killer fired during the wait) — verify mechanics
  Call: Mac only (AppKit first-responder code; iOS has no moveFocus) — Platform principle
  Tokens: 43.4M in (42.6M cache read), ≥185k out, 310 requests

Lane: B-453
  Branch: autopilot-lane/B-453
  Base: a7729797ae03c3d14c5e2da4fb6d79b9cc980774
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T00:52:06Z
  Reverifies: 0
  Reviewed-tip: dd560a065640a78394319de0a54498ee92324c0f
  Call: Mac only (iOS has no composer placeholder or send-gate logic) — Mac+iOS rule
  Call: Wording "<name> is still starting" repeats the daemon-reported state and matches the refusal and the Start bar — VISION 2
  Tokens: 7.94M in (7.66M cache read), ≥27.3k out, 92 requests

Lane: B-454
  Branch: autopilot-lane/B-454
  Base: bbc2501a8524ee3e8f7c06e693c3263a22f5526a
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T01:41:27Z
  Reverifies: 0
  Reviewed-tip: 5134f3b6833dd7f23de5e3ccd36d2992b58e6f8f
  Tokens: 7.6M in (7.31M cache read), ≥22.6k out, 86 requests

Lane: B-456
  Branch: autopilot-lane/B-456
  Base: 6350c9537c26aec686b8dfb962c1a0954191feff
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T02:52:54Z
  Reverifies: 0
  Reviewed-tip: none

Lane: B-458
  Branch: autopilot-lane/B-458
  Base: f8f3ecee98c333f9ddd6453bf134348305f40ed3
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T03:34:45Z
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-453 landed b18726f6e · not visually verified
Finished 2: B-454 landed a3738d88a · not visually verified
Finished 3: B-447 landed 79ec7ee26 · not visually verified
