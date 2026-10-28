Status: running
Started: 2026-10-28T01:47:16Z
Budget: 20 items, until 2026-10-28T13:47:16Z
Digested-through: 10
Filed: 1/3 bugs, 2/5 ideas
Self-filed: B-318 → B-325 bug — Edit ▸ Paste may lack ⌘V
Self-filed: B-059 → B-326 idea — iPad hardware-keyboard row switching
Self-filed: B-188 → B-327 idea — Remove the stale LeoHostSelection comment and dead spawn overload
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

Lane: B-172
  Branch: autopilot-lane/B-172
  Base: efb36873f1c56f4e2bc54ba6ea474d266071cebf
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d74f69857099e3a0392064699d516c656eb7ef56
  Tokens: 9.55M in (9.15M cache read), ≥42.8k out, 107 requests
  Dispatched: 2026-10-28T05:31:51Z
  Call: Drain pending reconciles in the public selectShownTerminal(in:), not in isOpen or the coordinator: keeps queries side-effect-free, adds no protocol method — bug fixes / Swift under macos/
  Call: B-172 is Mac only; host, terminal rows and Ghostty surfaces exist only under macos/ — AGENTS.md Mac+iOS rule
  Call: showTerminal still doesn't call onRowShown for the adopted shell; left out of scope since the B-274 rowReplaced hook already moves the row's pane mapping — small scope cut

Lane: B-173
  Branch: autopilot-lane/B-173
  Base: 85aa16a29b62f7595be5ef8f653c5fc9a5d20f4e
  Tier: light→full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 14d7e1c3efd4437ddbd3f1d9d762c3d3f53280ea
  Tokens: 14.6M in (13.9M cache read), ≥76.9k out, 173 requests
  Dispatched: 2026-10-28T07:21:28Z
  Call: Test-only focus drain (0.8 s main-queue timer outlasting the moveFocus retry chain), no production seam in Ghostty.moveFocus — flake fixes and test infrastructure; smallest correct change
  Call: Stall-mid-chain gap accepted and documented in the commit body — contrived coincidence under the severity bar
  Call: B-173 is Mac only (AppKit focus mechanism), no LeoKit/iOS change — AGENTS.md Mac+iOS rule

Lane: B-174
  Branch: autopilot-lane/B-174
  Base: 1ffc47d323181a3f43029c6a8603a7fb5fe6c303
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: a399ec1558a0eb087b15f42d9f57512e9337e91c
  Tokens: 6.12M in (5.86M cache read), ≥29.8k out, 77 requests
  Dispatched: 2026-10-28T08:07:04Z
  Call: B-174 is Mac only: Ghostty config doesn't exist on iOS, so no iOS backlog item — AGENTS.md Mac+iOS rule
  Call: Implement D-603 with a Leo defaults file (undo-timeout = 30s) loaded first in Ghostty.Config.loadConfig, so any explicit user value wins; no Zig changes — D-603, keep Zig changes minimal
  Call: The Leo defaults file is rewritten in the temp dir on each config load; if the write fails it logs and falls back to upstream's 5 s — reversible implementation call

Lane: B-175
  Branch: autopilot-lane/B-175
  Base: 7c777e514ae3a09b7c4bbc6a32c9ecd37a68d7c5
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Tokens: 8.07M in (7.9M cache read), ≥31.6k out, 80 requests
  Dispatched: 2026-10-28T08:28:09Z

Lane: B-059
  Branch: autopilot-lane/B-059
  Base: d0642c4a33a51f5365cdf4c35c325287455b6b25
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 443e3df3b882dcb9ec20b3747728ca62725ed822
  Tokens: 26.7M in (26.1M cache read), ≥126k out, 214 requests
  Dispatched: 2026-10-28T08:48:26Z
  Call: ⌃⇥/⌃⇧⇥ step to the next/previous row everywhere (overriding a user's ctrl+tab Ghostty keybind so it reaches the menu); ⇧⌘]/[ stay with editor tabs and fall through to rows when the pane has fewer than two editor tabs. Supersedes only D-460's clause that Ghostty next/previous_tab switches editor tabs — principle 1 (keyboard-first)
  Call: ⌘1–⌘8 select rows 1–8, ⌘9 is Last Row, and a number past the end clamps to the last row (Ghostty's goto_tab/last_tab behaviour) — principle 1
  Call: A navigable row is every row the list can select (agents, attachable dispatch rows, then this window's terminals); collapsed sections and folded/offline machines are skipped, and a search filter lists only matches — principle 6
  Call: Going to a row by keyboard acts like a single click, so a stopped agent gets the start prompt — principles 1 and 6
  Call: Window menu holds Select Next/Previous Row, a Select Row ▸ submenu (Row 1–8, Last Row) and Jump to Next Needing Attention, moved from the Agents menu with the same id, selector and ⌃⌥⌘J — principle 1
  Call: B-059 is Mac only; iPad row switching filed as a backlog idea — AGENTS.md Mac+iOS rule

Lane: B-183
  Branch: autopilot-lane/B-183
  Base: 5215b0778abda1c74ed00fdbc70cb3680c9a26fa
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: eef2ff51dc316ddc4334bbb2d3277367e82d630b
  Tokens: 6.78M in (6.45M cache read), ≥32k out, 82 requests
  Dispatched: 2026-10-28T09:37:09Z
  Call: Fix the clear-name/OSC-title race rather than dismiss it: a shell or TUI that retitles on every prompt reaches it, and the guard is small and Swift-only — bug fixes (AUTONOMY agent decides)
  Call: B-183 is Mac only: SurfaceView is AppKit and iOS has no row rename — AGENTS.md Mac+iOS rule
  Call: Keep Zig untouched: the guard sits in the Leo-owned leoSetUserTitle — AUTONOMY keep Zig changes minimal

Lane: B-188
  Branch: autopilot-lane/B-188
  Base: d771917ec14d23d0019d1d1814a346f5e4caa1bc
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Tokens: 4.44M in (4.22M cache read), ≥16.2k out, 58 requests
  Dispatched: 2026-10-28T10:23:48Z

Lane: B-194
  Branch: autopilot-lane/B-194
  Base: bf6814a87e3535682c70553b027a3d67f9d6c0d7
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: e56d40b287955c7aa69e5ca8b856da549097de26
  Tokens: 5.23M in (4.97M cache read), ≥24.6k out, 62 requests
  Dispatched: 2026-10-28T10:51:14Z
  Call: Fix the successor symbols (hostSelectionRunner/LeoHostSelection were deleted in a87b3b0db): LeoRuntime.init's machineRunner and LeoMachineConnectionEnvironment.init's runner lose their LeoProcessRunner() defaults, so a test that forgets either fails to compile — test infrastructure
  Call: B-194 is Mac only: iOS has no LeoRuntime or LeoMachineConnectionEnvironment — AGENTS.md Mac+iOS rule

Lane: B-199
  Branch: autopilot-lane/B-199
  Base: 7acfe0f8df20c6629a3c5ed901e7c221b85be5ef
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 57d57df29f2745661b46077cf9ab8a41a5c49921
  Tokens: 19.5M in (19M cache read), ≥92.4k out, 184 requests
  Dispatched: 2026-10-28T11:17:48Z
  Call: Mac only (the Quick Terminal is macOS UI, no iOS half) — Mac+iOS parity rule
  Call: Dismiss B-199 as a verification artifact: real clicks already close the panel; the re-open only appears when Peekaboo's window-focus step runs before the click (AX focus resigns key with no mouse-down) — the 'fixed or explicitly dismissed with a reason' criterion

Lane: B-227
  Branch: autopilot-lane/B-227
  Base: 4ac4fbf2928d6a7df8cd93397e0965de906b6236
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 70f028f2c12f7c81cbb1b5989d3c0c266ea52a15
  Tokens: 2.14M in (1.95M cache read), ≥15.6k out, 30 requests
  Dispatched: 2026-10-28T12:22:00Z
  Call: Gate lives in leo-release.yml (a ci job calls leo-ci.yml; build needs ci), not leo-build.yml, which workflow_dispatch also runs — AUTONOMY "agent decides" (test infrastructure / CI)
  Call: Gate on the whole leo-ci workflow, not only run-tests.sh (the item's preferred option, stronger gate) — AUTONOMY "agent decides"
  Call: Neither Mac nor iOS (CI only) — Mac+iOS parity rule

Lane: B-317
  Branch: autopilot-lane/B-317
  Base: 933b8fb30c53369bc34ab6c7596d2223a5027aa3
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-28T12:26:46Z

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
- B-172 runner: leo dispatch d-904a06e6ebc0 (implement role).
Finished 5: B-172 landed 41ba19a2d · not visually verified
- B-173 runner: leo dispatch d-8452801d9121 (implement role).
- B-173: first runner d-8452801d9121 reported blocked on an implementer permission prompt (rm of two lane symlinks) it couldn't answer; orchestrator allowed it, commit 2d62ef55f landed in the lane; fresh runner dispatched to integrate/review/verify.
Finished 6: B-173 landed 21d9b00d2 · not visually verified
- B-174 runner: leo dispatch d-7bde6c9abcdd (implement role).
Finished 7: B-174 landed 7673b4f6c · not visually verified
- B-175 runner: leo dispatch d-a35c6df4c0ab (implement role).
- B-175: runner d-a35c6df4c0ab reported blocked on implementer permission prompt (revert of NSLog instrumentation); orchestrator allowed it; implementer then reported not reproducible.
Finished 8: B-175 blocked
- B-059 runner: leo dispatch d-32e70823fb37 (implement role).
Finished 9: B-059 landed 7ace88fd6 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-059-10.png
- B-183 runner: leo dispatch d-4cc9e2c906e3 (implement role).
Finished 10: B-183 landed 1dc53327c · not visually verified
- B-188 runner: leo dispatch d-96c02afe603b (implement role).
Finished 11: B-188 done (no code change)
- B-194 runner: leo dispatch d-d13d78c89fb2 (implement role).
Finished 12: B-194 landed 1e566664b · not visually verified
- B-199 runner: leo dispatch d-b210ebfa1c0e (implement role).
Finished 13: B-199 done (dismissed, no code change)
- B-199: runner d-b210ebfa1c0e; fix then self-revert after root cause; dismissed as Peekaboo window-focus artifact; lane shelved autopilot-shelved/B-199.
- B-227 runner: leo dispatch d-93957ae9a828 (implement role).
Finished 14: B-227 landed 281443e38 · not visually verified
