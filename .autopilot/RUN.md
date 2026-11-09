Status: running
Started: 2026-11-09T00:06:13Z
Budget: 20 items, until 2026-11-09T12:06:13Z
Digested-through: 0
Filed: 1/3 bugs, 0/5 ideas
Self-filed: B-358 → B-368 bug — theProbeSurvivesTheSidebarResizingAfterItReported is flaky
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
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7cdb6cd815dea1e2daf0647397534a10cbf70271
  Dispatched: 2026-11-09T01:02:41Z
  Call: Scope the task panel to the open thread only, not to the list (iPad regular width hides other agents' tasks while a thread is open) — P2 calm, attention-driven
  Call: iOS only; the Mac task capsule is already per-agent — repo Mac/iOS rule

Finished 1: B-358 landed 060569e2011d6ddf5b4ebd017434812a80823a77 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-358-1.png

Progress:
- Preflight: autopilot fast-forwarded to main ab72de1f0 (bundled leo 0.76.0); inbox applied: created B-363–B-367 (bugs); B-358 promoted.
- B-367 blocked before pick: leo agent says the fix is daemon-side (leo PR #327); no app change.
- B-358 landed 060569e20 (light, 0 fixes).
- B-363: restored lane's ios/LeoFeatures/Package.resolved (Xcode 26.5 resolver artifact from test runs, not item work) before landing.
