Status: finished
Started: 2026-11-26T00:49:37Z
Budget: 20 items, until 2026-11-26T12:49:37Z
Digested-through: 5
Filed: 1/3 bugs, 3/5 ideas
Self-filed: B-453 → B-461 bug — resetWindowSizeRestoresALaunchClampedSidebar fails (200 vs 199) on autopilot
Self-filed: B-454 → dropped (dup of B-455) — Handoff banner ignores Return while caps lock is on
Self-filed: B-447 → dropped (dup of B-461) — resetWindowSizeRestoresALaunchClampedSidebar fails
Self-filed: B-447 → B-462 idea — Row/Rows suites run slower on each repeat in one process
Self-filed: B-447 → B-463 idea — leo-runtests.sh skips 129 host-tier suites (no TEST_RUNNER_LEO_HOST_TESTS=1)
Self-filed: B-456 → dropped (dup of B-456's own sentinel call) — Sentinel heuristic hides single-token underscore previews
Self-filed: B-456 → B-464 idea — Mac and iOS keep separate "Finished" fallbacks that can drift
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
  State: landed
  Fixes: 1
  Wip: none
  Dispatched: 2026-11-26T03:35:18Z
  Reverifies: 1
  Reviewed-tip: 03d16c6e282faf0b4784dbf1f336bb84482867c8
  Call: Treat any single snake_case token (one letter case, contains an underscore) as a sentinel, not a fixed list — VISION 2 Calm
  Call: Fix in LeoKit LeoInbox derivation only, no app changes; Mac headline and iOS card already fall back to "Finished" for a nil result — Mac+iOS rule
  Tokens: 12.7M in (12.1M cache read), ≥50.8k out, 149 requests

Lane: B-458
  Branch: autopilot-lane/B-458
  Base: f8f3ecee98c333f9ddd6453bf134348305f40ed3
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T03:34:45Z
  Reverifies: 0
  Reviewed-tip: 38821700bd93be43dc93689edb2577b8608a01dd
  Call: default off, so nothing changes until the owner opts in — AUTONOMY (defaults)
  Call: plain toggle in the existing Settings ▸ General page, new "Chat" section — VISION 1 / HIG
  Call: Mac only; iOS already opens chat images in a gallery viewer (ChatPresentation.swift:46) — Leo Mac+iOS rule
  Tokens: 9.76M in (9.45M cache read), ≥33.6k out, 104 requests

Lane: B-459
  Branch: autopilot-lane/B-459
  Base: 591dd515208cc89c99d83657e59470914b2bea13
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T04:42:01Z
  Reverifies: 2
  Reviewed-tip: f6a4491f5faa5f5ff8958dde172bdaad2d71b753
  Tokens: 13.6M in (12.9M cache read), ≥53.3k out, 165 requests

Lane: B-460
  Branch: autopilot-lane/B-460
  Base: 75933ad9c13f6b8caf620001e1c9f1badf501c5e
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-26T04:16:28Z
  Reverifies: 0
  Reviewed-tip: 2da73d1438dea4e15c062de72055588076ab3e71
  Tokens: 2.95M in (2.73M cache read), ≥17.2k out, 38 requests

Finished 1: B-453 landed b18726f6e · not visually verified
Finished 2: B-454 landed a3738d88a · not visually verified
Finished 3: B-447 landed 79ec7ee26 · not visually verified
Finished 4: B-456 landed e80427b9d · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-456-2.png
Finished 5: B-458 landed a10dda60e · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-458-1.png
Finished 6: B-460 landed 788909869 · not visually verified
Finished 7: B-459 landed b1d377b02 · not visually verified
