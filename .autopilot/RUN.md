Status: running
Started: 2026-10-28T01:47:16Z
Budget: 20 items, until 2026-10-28T13:47:16Z
Digested-through: 0
Filed: 1/3 bugs, 0/5 ideas
Self-filed: B-318 → B-325 bug — Edit ▸ Paste may lack ⌘V
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

Lane: B-318
  Branch: autopilot-lane/B-318
  Base: ca6b82515615918204128be2f2e6c6922f6253ec
  Tier: light→full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: dc0f12d06775accf2eb8edb95d232f4bacc840d1
  Dispatched: 2026-10-28T01:50:02Z
  Call: Mac only — iOS chat text is a selectable UITextView that copies without a menu shortcut (AGENTS.md parity rule)
  Call: Edit ▸ Copy gets ⌘C when the config gives it none and ⌘C is still bound (respects super+c=unbind and user-set shortcuts); dropped the plan's focus-on-mouse-down fix — Keyboard-first, Mac-native
  Call: Fix is app-wide: ⌘C also works for other selectable text and fields — Edit ▸ Copy / ⌘C must work wherever text is selectable

Lane: B-320
  Branch: autopilot-lane/B-320
  Base: d96154f93e73aaf5a7404d20fabe2b4fed39e43a
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 738ffb00bf111facebc1a16cf1f77789591a638d
  Tokens: 7.99M in (7.7M cache read), ≥35.2k out, 91 requests
  Dispatched: 2026-10-28T04:08:27Z
  Call: iOS only (UIKit layout under ios/; the Mac app doesn't use this view) — AGENTS.md Mac+iOS rule

Lane: B-321
  Branch: autopilot-lane/B-321
  Base: 6a74d3fd6bc33aae5c5cd295a8b462f4443764a4
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Tokens: 1.43M in (1.33M cache read), ≥8.48k out, 20 requests
  Dispatched: 2026-10-28T04:50:20Z

Lane: B-322
  Branch: autopilot-lane/B-322
  Base: ffd1217db72bda7e6b3bbefcc957138bf1b6da36
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7302c56887e654b3fb39278daf86a5d2e92139f9
  Tokens: 12.2M in (11.7M cache read), ≥64.5k out, 128 requests
  Dispatched: 2026-10-28T04:54:36Z
  Call: Gate test-host daemon isolation on the existing isRunningAsTestHost() rather than an env var, so plain xcodebuild and Xcode runs are isolated too — test infrastructure
  Call: The test host gets an unreachable socket (/dev/null/leo-test-host.sock) and no legacy :8370 web config, rather than a scratch daemon — test infrastructure
  Call: B-322 is Mac only; iOS has no local unix socket and LeoKit is unchanged — AGENTS.md Mac+iOS rule

Progress:
- Unlanded lane B-233 has no RUN.md block (left in place).
- B-318 runner: leo dispatch d-975afc371f24 (implement role).
Finished 1: B-318 landed 8d9135bb3 · not visually verified
- B-320 runner: leo dispatch d-ff8fb617a827 (implement role).
- B-320 lane: restored a verifier-regenerated ios/LeoFeatures/Package.resolved (B-321's subject) so the lane could land; diff saved to the session scratchpad.
Finished 2: B-320 landed f1ec80688 · not visually verified
- B-321 runner: leo dispatch d-65093f67540d (implement role).
Finished 3: B-321 blocked
- B-322 runner: leo dispatch d-6675f3229244 (implement role).
Finished 4: B-322 landed 67114465d · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-322-1.png
- verify.md: added B-322 daemon-isolation notes from the runner.
