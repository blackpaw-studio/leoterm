Status: running
Started: 2026-11-18T02:17:23Z
Budget: 20 items, until 2026-11-18T14:17:23Z
Digested-through: 10
Filed: 0/3 bugs, 3/5 ideas
Self-filed: B-324 → dropped (dup of B-324) — Mac: moved agent's row in a new window shows a dead Start prompt
Self-filed: B-218 → B-433 idea — Ghostty.sdef AppleScript dictionary still says Ghostty
Self-filed: B-371 → B-434 idea — iOS composer still sends to a stopped agent (starts it, no Start bar)
Self-filed: B-384 → B-435 idea — Task popover and header strip (LeoTaskDetailRow) still spin for indeterminate tasks
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
  Dispatched: 2026-11-18T05:31:25Z
  Base: 9721a21fae384b70dfb50af0a7043717b015cd36
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 1
  Tokens: 39.9M in (38.9M cache read), ≥139k out, 362 requests
  Reviewed-tip: 7997dbb8ed64f02be8c92aed89b47c47590cbd77
  Call: Refuse on the client; never let the daemon auto-start from the composer (the daemon starts a stopped agent on POST) — P2, D-724, item Out
  Call: Typing stays enabled; only send is gated and the draft is kept with a notice — P1
  Call: `.starting` sends; `.stopped`/`.unknown` refuse "isn't running"; `.restoring` refuses "still starting" — P2
  Call: Mac only; iOS untouched (its send starts the agent and it has no Start bar, D-723) — Mac/iOS rule
  Call: Refusal notice withdrawn on agent switch and once the agent becomes sendable — P2
  Call: Send arrow dimmed while refused — P1/HIG
  Call: Composer for a stopped agent: send arrow disabled, placeholder "Start <name> to send a message"; Return shows a warning banner and keeps the draft — P2

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
  Dispatched: 2026-11-18T06:44:02Z
  Base: ef717ca0d5ce6dc7047982bb96bbf869a468b02f
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 2
  Tokens: 14.9M in (14.3M cache read), ≥58.3k out, 176 requests
  Reviewed-tip: aa0161fc23623536d498e97e978b94dff15e8af0
  Call: Mac only (iOS task-row spinner is B-383) — AGENTS.md parity rule, D-743
  Call: Indeterminate capsule task shows the static working dot, not a spinner or an empty slot — VISION 2 calm
  Call: Stalled task shows the row's muted still pie (empty pie when there's no percent) — VISION 2 calm

Lane: B-383
  Branch: autopilot-lane/B-383
  Dispatched: 2026-11-18T05:57:38Z
  Base: 2baee02e635552aa1ca156ab675a5424d64126fd
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Tokens: 6.75M in (6.39M cache read), ≥28.6k out, 80 requests
  Reviewed-tip: d661e76ff620f8d1dffb01116341026af8c616e5
  Call: iOS only; Mac done in B-381, no LeoKit change since the Mac filters in its own presentation — AGENTS.md platform rule, D-743
  Call: Indeterminate task shows nothing on the iOS row (new iOS-side shownOnRow filter); determinate shows a static pie — P2 calm, D-744
  Call: Other iOS spinners (agent-detail action row, pairing, chat image) left alone — D-748

Lane: B-382
  Branch: autopilot-lane/B-382
  Dispatched: 2026-11-18T06:34:31Z
  Base: a657fde4535a6874bbc339e8176599036b4ffdeb
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 7.56M in (7.27M cache read), ≥26.7k out, 86 requests
  Reviewed-tip: b92753564bf562968d3fa050969e55838a1b4e6b
  Call: Show Tasks sits right after "Open in New Window" in the agent row context menu — P1 (every action has a menu item, HIG)
  Call: Show Tasks is hidden, not disabled, when there is no task (sidesteps the B-329/B-335 menu-enablement quirks) — P1
  Call: Show Tasks is shown even when an error or warning takes line 2, and for indeterminate tasks — item Note, VISION 1
  Call: Mac only (iOS has its own fleet task panel, Fleet+TaskPanel.swift) — Mac/iOS parity rule

Lane: B-428
  Branch: autopilot-lane/B-428
  Dispatched: 2026-11-18T07:04:55Z
  Base: 53ad53212034dcc6242300e663e5731d645059e7
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Tokens: 11M in (10.7M cache read), ≥33.6k out, 116 requests
  Reviewed-tip: 5cdaa3ed4c0ed74cbaf72dbe8e76e6070f6ba8a4
  Call: Mac only: AppKit address bar in the browser pane — D-925/D-929

Lane: B-351
  Branch: autopilot-lane/B-351
  Dispatched: 2026-11-18T08:15:33Z
  Base: c3edc651e19931e4ee05bf63536f75c773495d9d
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 1
  Tokens: 15.7M in (15.2M cache read), ≥52k out, 170 requests
  Reviewed-tip: 14b99543ae9a45ca0565a9d5f32ac6561f2e6ac5
  Call: Mac only: iOS already shows a refusal as an alert (D-779), and its stage display is deferred to B-396 — Mac/iOS parity rule
  Call: Move errors wrap to two lines, then truncate; the tooltip is unchanged — P2 Calm
  Call: Only the .error detail wraps, to at most two lines; other details stay one line at a fixed height, so only an error can make a row grow — P2 Calm, P6

Lane: B-335
  Branch: autopilot-lane/B-335
  Dispatched: 2026-11-18T08:11:41Z
  Base: d3d6a40d14c4ceaec300f6ff027fff9c98c48066
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-182
  Branch: autopilot-lane/B-182
  Dispatched: 2026-11-18T08:49:33Z
  Base: f5a652f100d9f11ef4f4ad2d8450a80fc69909bf
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
- B-371 ready (fix 1, general full + delta, 5035 tests, window shots). Calls vs D-723..D-726, D-948: consistent. Integration stale (B-218, B-388 landed) → re-verify round 1. Note: a "Leo quit unexpectedly" dialog appeared during its verify; debug app survived, cause unconfirmed.
- Dispatched B-371 re-verify d-b2aa58412a71.
- B-371 re-verify 1 ready (general delta, 5037 tests, window shot). Fresh.
- B-371 landed 4a8cda645. D-957..D-963.
Finished 6: B-371 landed 4a8cda645 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-371-1.png
- Pick: B-383 light (iOS task-row spinner; independent of B-384's Mac capsule). Dispatched d-eb495c0a2ed1.
- B-384 ready (general full, 5032 tests, not visually verified: no capsule fixture for running/stalled tasks). Calls vs D-743..D-748: consistent. Integration stale (B-371 landed) → re-verify round 1.
- Dispatched B-384 re-verify d-abd342466908.
- B-383 ready (fix 1, general full + delta, iOS LeoTests 125 + LeoKit 1900 green, not visually verified: no live indeterminate-task fixture). Calls consistent with D-743..D-748. Fresh. Unchecked: VoiceOver spokenValue may still read an indeterminate task.
- B-383 landed 82075531a. D-964..D-966.
Finished 7: B-383 landed 82075531a · not visually verified
- Pick: B-382 light (row context menu Show Tasks; B-351 skipped ahead? no — B-382 is next in order). Dispatched d-8c459759d9aa.
- B-384 re-verify 1 ready (general delta, 5040 tests). Stale again (B-383 landed, iOS-only files) → re-verify round 2; no new lane opens until it lands. Polish "eyeball muted-pie contrast" not filed (its own re-check).
- Dispatched B-384 re-verify 2 d-b4f5fd176179.
- B-384 re-verify 2 ready (general delta, 5040 tests, 3 window shots: determinate/indeterminate/stalled). Fresh.
- B-384 landed 3ca216725. D-967..D-969.
Finished 8: B-384 landed 3ca216725 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-384-1.png
- Pick: B-428 light (address bar drag-select; B-428 built before B-351 (independent; B-351 shares the sidebar row with open B-382)). Dispatched d-6bb022028a69.
- B-382 ready (general full, 5041 tests, window shot). Calls vs D-745/D-766/D-770: consistent. Fresh. Verifier saw a "Configuration Errors" dialog from verify.md's launch args (-ApplePersistenceIgnoreState YES), not this change.
- B-382 landed c69660e66. D-970..D-973.
Finished 9: B-382 landed c69660e66 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-382-0.png
- Pick: B-351 light (sidebar row move error wraps to two lines). Dispatched d-24c84ce977b0.
- B-428 ready (general full, 5042 tests, not visually verified: browser pane needs a scratch daemon; tests post synthetic NSEvents). Fresh.
- B-428 landed 580e44c07. D-974..D-974.
Finished 10: B-428 landed 580e44c07 · not visually verified
- Interim digest 2 posted (items 6–10).
- Pick: B-335 light (row menu submenu-parent enablement; independent of B-351's error line). Dispatched d-3bfa9172408b.
- B-351 ready (general full, 5042 tests, window shot). Note: the fixture refusal needs ~3 lines, so the 2-line cap still truncates its last words; tooltip has the full text. Stale (B-428 landed) → re-verify round 1.
- Dispatched B-351 re-verify d-c384f97f449f.
- B-351 re-verify 1 ready (general delta, 5043 tests; GUI unchanged since first verify's window shot). Fresh.
- B-351 landed e5155196e. D-975..D-977.
Finished 11: B-351 landed e5155196e · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-351-2.png
- Pick: B-182 light (restored terminal name clear → live title; independent of B-335). Dispatched d-c33141168cbe.
