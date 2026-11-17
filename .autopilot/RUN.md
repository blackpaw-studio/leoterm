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
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Tokens: 15.4M in (14.9M cache read), ≥55.1k out, 152 requests
  Reviewed-tip: db3b550f21b8f8116f61b115636703e98129dfa2
  Call: iOS only; the crash is in the hosted iOS LeoTests and no LeoKit code is involved — AUTONOMY (bug/flake fixes; state the platform call)
  Call: Test-host-only gate (LaunchPolicy.send, active only when XCTestConfigurationFilePath is set); PushCleanupClient, PushNotifications and AppFeature untouched, product behavior unchanged — AUTONOMY (test-only fix)
  Call: Gated every lifecycle send (.task and both scene-phase sends) instead of stubbing dependencies — closes all routes to unimplemented test values

Lane: B-426
  Branch: autopilot-lane/B-426
  Dispatched: 2026-11-17T20:14:22Z
  Base: 8c72a4a605b90d57a55a36021ed847686a692b78
  Tier: light
  State: building
  Fixes: 1
  Wip: none
  Reverifies: 1
  Reviewed-tip: a0cb2acc6c772d7945f71efc5977b57747a22317
  Call: Mac only: AppKit pane UI, nothing in LeoKit — D-925 / AUTONOMY
  Call: After Return the bar shows the typed address while the page loads, then follows the page again — P1 Safari parity, D-928
  Call: A failed or cancelled load, or a navigation that can't start, drops the typed address and shows the page URL — P2, D-928

Finished 1: B-422 landed dcd049de7 · not visually verified

Progress:
- Preflight: no open bump/leo-* PR. main already merged. Inbox empty. Promoted B-422, B-426, B-427. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Pick: B-422 light bug (iOS test-host flake; the crash is in the test harness, not the product) and B-426 light bug (Mac address bar) in parallel — independent footprints. B-427 overlaps B-426 (Return commit in the pane); waits.
- Dispatched runners via leo_dispatch implement: B-422 d-757db1906f31, B-426 d-60cb459aa32c.
- B-422 ready (fix 1, general review, full suite green, mutation check reproduces). Not visually verified: no UI change. Fresh.
- B-422 landed dcd049de7. D-934..D-936. ≈$4.52 est.
- B-426 ready (fix 1, general review, 5026 tests). Not visually verified: no browser-pane GUI recipe in verify.md. Calls checked vs D-925..D-931: consistent (Escape during a pending load restores the typed address — treated as the loading page's address, not a D-926 contradiction). Integration stale (B-422 landed iOS files) → re-verify round 1.
- Dispatched B-426 re-verify d-c334ea57ed5c.
