Status: running
Started: 2026-11-18T02:17:23Z
Budget: 20 items, until 2026-11-18T14:17:23Z
Digested-through: 5
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-324 → dropped (dup of B-324) — Mac: moved agent's row in a new window shows a dead Start prompt
Self-filed: B-218 → B-433 idea — Ghostty.sdef AppleScript dictionary still says Ghostty
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

Lane: B-324
  Branch: autopilot-lane/B-324
  Dispatched: 2026-11-18T02:20:50Z
  Base: 0d5f7905144bee64282629117d65a23a915c7063
  Tier: full
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 5.33M in (4.91M cache read), ≥58.1k out, 58 requests
  Reviewed-tip: none
  Call: A moved row opened in a new window shows its chat, like a plain click on a non-running row (B-369), instead of a Start prompt — VISION 2, 6

Lane: B-431
  Branch: autopilot-lane/B-431
  Dispatched: 2026-11-18T02:20:50Z
  Base: 0d5f7905144bee64282629117d65a23a915c7063
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 7.35M in (7.15M cache read), ≥25.6k out, 69 requests
  Reviewed-tip: none

Lane: B-432
  Branch: autopilot-lane/B-432
  Dispatched: 2026-11-18T02:28:13Z
  Base: a9176ea11fb746ed8d62c9f4e5d5b350c609690d
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 3.04M in (2.9M cache read), ≥11.9k out, 35 requests
  Reviewed-tip: none
  Call: iOS only; LeoKit isn't involved — AUTONOMY (state the platform call)

Lane: B-218
  Branch: autopilot-lane/B-218
  Dispatched: 2026-11-18T02:44:48Z
  Base: fd620fa06078e8115e1e353b8f7779aaae993cd2
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Tokens: 10.7M in (10.3M cache read), ≥49.9k out, 120 requests
  Reviewed-tip: 84fcfc5f1344684191609dfa8ef4389e0a80c698
  Call: Product name is the literal "Leo" in alerts, palette, popovers, accessibility labels and window titles — P1
  Call: Kept the 👻 prefix in default window titles ("👻 Leo") — P1
  Call: Platform: Mac only; no "Ghostty" string in ios/ or Packages/ — Mac/iOS parity rule

Lane: B-371
  Branch: autopilot-lane/B-371
  Dispatched: 2026-11-18T02:54:06Z
  Base: 9721a21fae384b70dfb50af0a7043717b015cd36
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-388
  Branch: autopilot-lane/B-388
  Dispatched: 2026-11-18T04:05:54Z
  Base: 8a7820117a218fc1cad37e3f095f07ada2505264
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 6.47M in (6.2M cache read), ≥20k out, 75 requests
  Reviewed-tip: a1970295a30120ccaf48f4bb0aebba849bb95818
  Call: Mac test target only (macos/Tests/Leo); LeoKit's helper already defaults to 10 s and iOS is unaffected — AUTONOMY: flake fixes are agent-decides
  Call: Raise the Mac awaitCondition default bound to 10 s, no sleeps, assertions unchanged — AUTONOMY: fix at the cause

Lane: B-384
  Branch: autopilot-lane/B-384
  Dispatched: 2026-11-18T05:15:12Z
  Base: ef717ca0d5ce6dc7047982bb96bbf869a468b02f
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
- Preflight: no open bump/leo-* PR. main merged (2 LeoKit files). Inbox: 5 entries applied — B-431, B-432 bugs; 13 ideas promoted; 10 blocked items closed not reproducible (B-317 B-321 B-338 B-344 B-367 B-373 B-374 B-375 B-393 B-427); B-324 ready for a live move check; B-311 re-blocked (answer needs a hosted-CI run = push). No ready (next run) items. Stale B-426 block (landed 2e7220332, block said building) dropped.
- Pick: B-324 full (Mac UI shipped in leo-v0.28.0; needs live move verify + iOS check) and B-431 light bug (macOS CI hang in browser downloads tests) in parallel — independent footprints.
- Dispatched runners via leo_dispatch implement: B-324 d-50c4c1aa6949, B-431 d-6a406081d874.
- B-324 blocked: planner audit says 13/14 criteria met; one Mac new-window gap; live cross-host Move needs a second leo host (only Evan's real daemons) → asks to accept live Duplicate + daemon Move refusal instead. Shelved on autopilot-shelved/B-324. Polish bug dropped as dup of B-324's own gap.
- B-324 ≈$2.07 est.
- Pick: B-432 light bug (iOS CI App-tests flake; independent of B-431). Dispatched d-2d336b519884.
Finished 1: B-324 blocked
- B-432 blocked: couldn't reproduce (8/8 alone, 125/125 full bundle ×5 incl. fresh-erased sim; ~4 s vs 32.7 s in CI). CI log: first WebKit use timed out at the 28 s navigation deadline on a cold WebContent/Networking start. Shelved on autopilot-shelved/B-432.
Finished 2: B-432 blocked
- Pick: B-218 light (copy: Ghostty branding in user-facing strings). Dispatched d-01be07a9d7a0.
- B-431 blocked: couldn't reproduce (download tests 25× isolated, all pass ~12 s; full single-host runs timed out elsewhere under load 125–180). Shelved on autopilot-shelved/B-431.
Finished 3: B-431 blocked
- Pick: B-371 full (composer behavior, parity call; B-388 waits). Dispatched d-273e47e89288.
- B-218 ready (fix 1, general full + delta review, window shot). Calls vs D-793/D-801: consistent. Fresh. Full suite had one unrelated flake per run under load (LeoTitleIntegrationTests known flaky; LeoMachineStatsPollerTests reconnect) — re-run at merge gate.
- B-218 landed 4be252b4f. D-952..D-954. Filed B-433 idea (Ghostty.sdef).
Finished 4: B-218 landed 4be252b4f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-218-1.png
- Pick: B-388 light (test flake fix). Dispatched d-6be9d413e408.
- B-388 ready (general full review, full suite 5029 green, not visually verified: test-only). Acceptance partly unmeasured: no repeated series at load >30 (targeted run passed at load 72–114). Fresh.
- B-388 landed dd1f3def2. D-955..D-956.
Finished 5: B-388 landed dd1f3def2 · not visually verified
- Interim digest 1 posted (items 1–5).
- Pick: B-384 light (Mac toolbar capsule spinner). Dispatched d-c5112f76f5b7.
