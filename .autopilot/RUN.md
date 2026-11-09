Status: running
Started: 2026-11-09T00:06:13Z
Budget: 20 items, until 2026-11-09T12:06:13Z
Digested-through: 0
Filed: 1/3 bugs, 1/5 ideas
Self-filed: B-358 → B-368 bug — theProbeSurvivesTheSidebarResizingAfterItReported is flaky
Self-filed: B-365 → dropped (dup of B-218) — "Quit Ghostty?" confirm alert still says Ghostty
Self-filed: B-365 → dropped (dup of B-218) — Window menu entry and titlebar still read "👻 Ghostty"
Self-filed: B-365 → B-370 idea — verify.md launch line's -ApplePersistenceIgnoreState YES shows a Configuration Errors dialog
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

Lane: B-358
  Branch: autopilot-lane/B-358
  Base: a746aed32327b51b0afa4dfbf73840b17d907a46
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 718d936598c7e8d05ad0c8183b727648d79f1880
  Call: Mac only, since iOS has no split zoom — P1
  Call: Native bordered image toolbar item `.leoResetZoom` (before `.leoUpdate` and `.leoMore`) in place of the `.right` titlebar accessory; other window styles keep the accessory — P1
  Call: Item uses visibilityPriority .high and never gives way to the activity capsule, since it is an action — P2
  Dispatched: 2026-11-09T00:07:58Z
  Tokens: 10.8M in (10.5M cache read), ≥47.3k out, 111 requests

Lane: B-363
  Branch: autopilot-lane/B-363
  Base: ee4c648d6b9b9f75a2ed0fec7d9c464c39338452
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7cdb6cd815dea1e2daf0647397534a10cbf70271
  Dispatched: 2026-11-09T01:02:41Z
  Tokens: 5.81M in (5.55M cache read), ≥24k out, 71 requests
  Call: Scope the task panel to the open thread only, not to the list (iPad regular width hides other agents' tasks while a thread is open) — P2 calm, attention-driven
  Call: iOS only; the Mac task capsule is already per-agent — repo Mac/iOS rule

Lane: B-364
  Branch: autopilot-lane/B-364
  Base: 42ee099741936e2f2ba1a09db0d28b6a40b904ea
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: ab9a005bf9caf769f609746d65198433dd0ff08d
  Dispatched: 2026-11-09T01:29:45Z
  Tokens: 8.19M in (7.83M cache read), ≥37.7k out, 95 requests
  Call: Mac only — the managed daemon exists only in the macOS app, and iOS had no such migration (matches D-670)
  Call: No `PUT /config/defaults` fallback — leo 0.76.0 defaults placement to window, so the app has nothing to set (P2/P4)
  Call: Moved the post-launch sequence into `LeoManagedStartup.runPostLaunchSteps()` so it can be tested, with no behaviour change — test detail

Lane: B-365
  Branch: autopilot-lane/B-365
  Base: 738ac477e3d166a10423b58bfea424738a1b966d
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1d8ce79db3a5eb66e0a0b2b41be1201cc018db20
  Dispatched: 2026-11-09T02:09:17Z
  Tokens: 18.2M in (17.8M cache read), ≥50.5k out, 179 requests
  Call: "Leo Help" retitled along with the three items in the screenshot — P1 (first-party Mac feel)
  Call: Mac only: the menu bar has no iOS equivalent — repo rule
  Call: Built the xcframework inside the lane because shared/ predates the B-334 symbol; src/ untouched — verify.md

Lane: B-369
  Branch: autopilot-lane/B-369
  Base: ee9831926b78d9e6a7a2191a13134e24abce8813
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-09T02:17:01Z

Lane: B-366
  Branch: autopilot-lane/B-366
  Base: 1239bee56117fdf3d8cbc0ad0248de87427ca677
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-09T04:17:29Z

Finished 1: B-358 landed 060569e2011d6ddf5b4ebd017434812a80823a77 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-358-1.png
Finished 2: B-363 landed 581bfebf38a798ceb244462f2fa88525fdf346d0 · not visually verified
Finished 3: B-364 landed d6421b4df185b95b0eb0a8a8b42235da72355cb2 · not visually verified
Finished 4: B-365 landed 6455f1a0974e47b9f77472b9f6ca50f173a38170 · screen capture, not attached

Progress:
- Preflight: autopilot fast-forwarded to main ab72de1f0 (bundled leo 0.76.0); inbox applied: created B-363–B-367 (bugs); B-358 promoted.
- B-367 blocked before pick: leo agent says the fix is daemon-side (leo PR #327); no app change.
- B-358 landed 060569e20 (light, 0 fixes).
- B-363: restored lane's ios/LeoFeatures/Package.resolved (Xcode 26.5 resolver artifact from test runs, not item work) before landing.
- B-363 landed 581bfebf3 (light, 0 fixes).
- Inbox applied: B-369
- Parallel builds on (owner, 2026-11-08); B-364 runner predates the test-host lock rule.
- B-364 landed d6421b4df.
- B-364 verifier saw unrelated flakes (allThreeWindowButtonsAreVisible, aSlowFetchForOneMachineNeverLandsInAnotherMachinesList, theProbe…) while B-365 ran in parallel without a parent baseline.
- B-369 built before B-366 (independent; B-366 overlaps B-365's AppDelegate footprint).
- B-365 landed 6455f1a09.
