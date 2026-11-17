Status: running
Started: 2026-11-17T18:31:40Z
Budget: 20 items, until 2026-11-18T06:31:40Z
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

Lane: B-422
  Branch: autopilot-lane/B-422
  Dispatched: 2026-11-17T18:34:24Z
  Base: 8c72a4a605b90d57a55a36021ed847686a692b78
  Tier: light
  State: verifying
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: db3b550f21b8f8116f61b115636703e98129dfa2
  Call: iOS only; the crash is in the hosted iOS LeoTests and no LeoKit code is involved — AUTONOMY (bug/flake fixes; state the platform call)
  Call: Test-host-only gate (LaunchPolicy.send, active only when XCTestConfigurationFilePath is set); PushCleanupClient, PushNotifications and AppFeature untouched, product behavior unchanged — AUTONOMY (test-only fix)
  Call: Gated every lifecycle send (.task and both scene-phase sends) instead of stubbing dependencies — closes all routes to unimplemented test values

Lane: B-426
  Branch: autopilot-lane/B-426
  Dispatched: 2026-11-17T18:34:24Z
  Base: 8c72a4a605b90d57a55a36021ed847686a692b78
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
- Preflight: no open bump/leo-* PR. main already merged. Inbox empty. Promoted B-422, B-426, B-427. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Pick: B-422 light bug (iOS test-host flake; the crash is in the test harness, not the product) and B-426 light bug (Mac address bar) in parallel — independent footprints. B-427 overlaps B-426 (Return commit in the pane); waits.
- Dispatched runners via leo_dispatch implement: B-422 d-757db1906f31, B-426 d-60cb459aa32c.
- B-422 ready (fix 1, general review, full suite green, mutation check reproduces). Not visually verified: no UI change. Fresh.
