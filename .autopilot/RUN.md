Status: running
Started: 2026-10-27T01:43:03Z
Budget: 20 items, until 2026-10-27T13:43:03Z
Digested-through: 11
Filed: 1/3 bugs, 5/5 ideas
Self-filed: B-304 → B-312 idea — Add an iOS simulator + fixture-daemon recipe to verify.md
Self-filed: B-304 → B-313 idea — Update iOS Machines meters in place instead of rebuilding the row's meter line
Self-filed: B-307 → B-314 idea — Full Leo-browser explanation on browser_tabs and browser_snapshot too
Self-filed: B-307 → B-315 idea — Consider renaming Leo browser tools to leo_browser_*
Self-filed: B-309 → B-316 idea — Check a 100% Rings stat: "100" may sit tight against the stroke
Self-filed: B-311 → B-317 bug — Key-window tests all skip on Dionysus while two system prompts hold the foreground
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
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-304
  Branch: autopilot-lane/B-304
  Base: a7b1c1819c701c3da306e7a178a6b7959424e995
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: f95863101be4e1158c3b5966ada9caa34c596bbe
  Tokens: 29.8M in (29.2M cache read), ≥100k out, 234 requests
  Dispatched: 2026-10-27T01:44:55Z
  Call: iOS only (the Mac list is a different view; no LeoKit change) — Mac + iOS parity rule
  Call: leave the CPU gauge blue→red flip unchanged; it reflects real data (≥0.9 is `.critical`), and smoothing or hysteresis would be a product call — never invent a state the daemon didn't report
  Call: drop `Identifiable` from `MachineSettings.State` (keeps its `id` property) — agent decides bug fixes

Lane: B-306
  Branch: autopilot-lane/B-306
  Base: 890ee6df384a4931967c0926dbb891baa591ddba
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d68b956464451e69e42fda9f97388be2402d57d1
  Tokens: 4.15M in (3.84M cache read), ≥20.6k out, 57 requests
  Dispatched: 2026-10-27T03:30:44Z
  Call: Mac only (iOS executor not built); fix is in shared LeoKit — Mac + iOS parity rule
  Call: Only browser_navigate auto-opens a tab; snapshot and other page tools with no tab still return no_such_tab — agent decides bug-fix scope
  Call: Tool names and wire shapes unchanged — shared client-tools contract

Lane: B-307
  Branch: autopilot-lane/B-307
  Base: e93b628b691a25c439a9b1dcd716bcc03b309c81
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 3555d87e77594f4f08a2beaa2beac667fa5e3e94
  Tokens: 3.33M in (3.12M cache read), ≥17.6k out, 45 requests
  Dispatched: 2026-10-27T03:45:17Z
  Call: Description-only fix; tool names, schemas and wire shapes unchanged — D-553, shared client-tools contract
  Call: Mac only, code in shared LeoKit — D-551
  Call: Regenerated leoterm-only golden Fixtures/agent-browser/browser-tools.json; shared client-tools wire fixtures untouched — agent decides test infrastructure

Lane: B-308
  Branch: autopilot-lane/B-308
  Base: 81bf8c3187859bb0b4099e4e9736fdee7fb15be5
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: c00363c356eec757eb1466d11cfea33fa652f554
  Tokens: 8.64M in (8.27M cache read), ≥38.2k out, 100 requests
  Dispatched: 2026-10-27T03:58:20Z
  Call: Mac only: Settings ▸ Machines is a macOS view; iOS Machines list is separate (D-548) — Mac + iOS parity rule
  Call: Scroll the Machines detail form instead of enlarging the minimum window — agent decides layout/UX details

Lane: B-309
  Branch: autopilot-lane/B-309
  Base: 81e7f33c655611fd58abfca868f0ace8841d40c6
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 03ca17caacc3e78dbfdb03f51a6033171b1cc766
  Tokens: 6.59M in (6.32M cache read), ≥30k out, 78 requests
  Dispatched: 2026-10-27T04:25:09Z
  Call: Mac only (iOS MeterLineView draws Rings with 16pt spacing and no stroke overflow) — Mac + iOS parity rule
  Call: 5pt Rings spacing (capsules stay 3pt) — agent decides layout details

Lane: B-311
  Branch: autopilot-lane/B-311
  Base: 1f12415b47a3571e8486a547ff8ac845ac946d6e
  Tier: full
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Tokens: 11.5M in (11.2M cache read), ≥92k out, 105 requests
  Dispatched: 2026-10-27T04:53:32Z
  Call: Fix at the spawn site (clear the signal mask in Pty.childPreExec) as well as at the leak source — agent decides bug fixes (planned, not built)
  Call: Mac only; iOS spawns no local ptys — Mac + iOS parity rule

Lane: B-158
  Branch: autopilot-lane/B-158
  Base: 2daa1d034daf327243239bc7454567c0cb9e8245
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: a660574f9934b0cbd50208ac97a8a42f8db56440
  Tokens: 2.63M in (2.43M cache read), ≥13.2k out, 36 requests
  Dispatched: 2026-10-27T05:25:08Z
  Call: Mac only: menu shortcut test helper lives in macos/Tests; iOS has no equivalent — Mac + iOS parity rule (AGENTS.md).

Lane: B-159
  Branch: autopilot-lane/B-159
  Base: a4418b477d7c87aa35ed749bb3a2a88bec832740
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d267723f6a85dd119f6a4711e004d91328d7c008
  Tokens: 3.44M in (3.23M cache read), ≥16.3k out, 46 requests
  Dispatched: 2026-10-27T05:41:09Z
  Call: Mac only: menu shortcut test helper lives in macos/Tests; iOS has no equivalent — D-562; Mac + iOS parity rule.
  Call: Case table, private ShortcutCase struct and xibDocument helper stay in the same test file — AUTONOMY: test infrastructure; matches surrounding code.

Lane: B-160
  Branch: autopilot-lane/B-160
  Base: 5a7def29c076d842489739ccafe37f872050362c
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7823c541f64accebe1e58c4f6a8dbd4ac784e013
  Tokens: 4.34M in (4.12M cache read), ≥15.3k out, 57 requests
  Dispatched: 2026-10-27T06:08:45Z
  Call: Mac only; the change stays in the same menu-shortcut test file — D-562/D-563/D-564; Mac + iOS parity rule.

Lane: B-161
  Branch: autopilot-lane/B-161
  Base: cb278b1237a566182479a33e0901953fa0c12b50
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: cf0811912b911d9fa88c25afe5c83656ea66b3ec
  Tokens: 3.67M in (3.45M cache read), ≥18.8k out, 49 requests
  Dispatched: 2026-10-27T06:27:21Z
  Call: Mac only: the retitle pixel probe is an AppKit test with no iOS counterpart — Mac + iOS parity rule.
  Call: settledDrawingEnd returns the title's drawn end only once two consecutive turns agree; before and after both use it — AUTONOMY: test infrastructure, flake fixes.
  Call: The after measurement must settle on an end != the old one, dropping the dependency on "vim notes.md" drawing wider than "Terminal" — AUTONOMY: test infrastructure; removes a font/fixture dependency.

Lane: B-162
  Branch: autopilot-lane/B-162
  Base: c86c925abe54eb26b07392c05c93669d65135632
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: e91c542ba7eda475fc44a81b4741d7283eaa7de4
  Tokens: 3.51M in (3.29M cache read), ≥17.8k out, 47 requests
  Dispatched: 2026-10-27T06:40:04Z
  Call: Mac only: test-helper change — D-566/D-568; Mac + iOS parity rule.
  Call: Renamed to turnsUntil(limit:_:) (not (_:limit:)) so trailing-closure callers resolve cleanly — AUTONOMY: naming, test infrastructure.
  Call: Fixed all three private copies of the helper (LeoTerminalRowsIntegrationTests, LeoSidebarTerminalScrollTests, Editor/LeoRowPaneCloseTests) and ~50 callers — AUTONOMY: test infrastructure; update every caller.
  Call: No new test for the helper (private to test files, no seam) — TDD exception: test infrastructure.

Lane: B-163
  Branch: autopilot-lane/B-163
  Base: ab1af110c7e5bed576b25c60830eb6a156faf283
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 66832d3e9fd46bdc32c3fb092198eb9c2e1483f3
  Tokens: 2.72M in (2.52M cache read), ≥13.7k out, 38 requests
  Dispatched: 2026-10-27T06:51:38Z
  Call: Mac only: test comments only — D-566/D-569; Mac + iOS parity rule.

Lane: B-164
  Branch: autopilot-lane/B-164
  Base: 5afbc36bcb5e2a2588a7de722178798ea717fb36
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 0cc082de2eb0e917fbf46cc12bf2562123eb67bb
  Tokens: 10.9M in (10.5M cache read), ≥45.4k out, 128 requests
  Dispatched: 2026-10-27T07:01:46Z
  Call: Map F1–F25 only in Ghostty.keyToEquivalent (AppKit NSF<n>FunctionKey equivalents) — AUTONOMY: keep the upstream-shaped diff minimal.
  Call: Spell F-keys "F<n>" in KeyboardShortcut.keyList; functionKeyName lives in a KeyEquivalent extension shared with LeoShortcutHints — One source of truth; fixes raw private-use glyphs in the palette, key-sequence overlay and goto_tab tooltips.
  Call: Mac only: menus and NSMenuItem equivalents don't exist on iOS — Mac + iOS parity rule.

Lane: B-165
  Branch: autopilot-lane/B-165
  Base: 36d4d57e7f9b12d7759dd1141579f3101a2d371f
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: b5350e74eaaf8b1cf628155d36ff55f7d899cf0d
  Tokens: 4.15M in (3.93M cache read), ≥16.5k out, 54 requests
  Dispatched: 2026-10-27T08:16:48Z
  Call: Mac only (test-only); the Quick Terminal test's chooseAgent: use and the manual addItem in aSyncWithUnchangedShortcutsDoesNotPublish are left alone as out of scope — D-576; Mac + iOS parity rule; no mid-task scope growth.

Lane: B-166
  Branch: autopilot-lane/B-166
  Base: 368cacc471487f2a5094cdc917028d19ad860bdc
  Tier: full
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 8ba251969b37cad5e1aabc29bdffcc49dcfae3e1
  Dispatched: 2026-10-27T08:44:24Z
  Call: Arm LEO_FORCE_DISCONNECTED inside the feed, keyed on registry generations (>0), instead of delaying the local feed's early start — AUTONOMY: bug fixes; production launch behaviour unchanged.
  Call: Mac-only fix, no iOS fixture — Mac + iOS parity rule: iOS and LeoKit never read the variable.
  Call: On the forced path the list handler returns right after emit(), skipping state fetch, metadata refresh and onManualRefresh (DEBUG only) — AUTONOMY: test infrastructure; fixture stays out of release builds.
  Call: No test for arming while the feed is already connected — Production always arms before start.
Finished 1: B-304 landed 31af2cd81a240f9aee424078b60cdb2b89754b0c · not visually verified
Finished 2: B-306 landed 99a867a7ed078dfb6c4e172bd9c174c646a825e1 · not visually verified
Finished 3: B-307 landed 7897c4422dfb50e8fff1288d5a1de2b0ac80c328 · not visually verified
Finished 4: B-308 landed 0c815dad1f43d1961a60d42261f3b417893b6b7c · not visually verified
Finished 5: B-309 landed 63f8938afaf00b41dbde2c9a591b65153c9177e1 · not visually verified
Finished 6: B-310 done (no code change)
Finished 7: B-311 blocked
Finished 8: B-158 landed 41fbcdc17f1c8f58cfd2cb4ef334d041283ded70 · not visually verified
Finished 9: B-159 landed bb8256e4b1afe7414ac134c927a9573650e882af · not visually verified
Finished 10: B-160 landed b4d57be051f3861b77302513cae0ceafef653134 · not visually verified
Finished 11: B-161 landed 39aa42ae7db920b969e927bbb99a0f11a53f1d32 · not visually verified
Finished 12: B-162 landed d9ac81ce56062a46b73357887d1c93c82e5e223a · not visually verified
Finished 13: B-163 landed b5f4818894a4e346d586e03e472716330e30270d · not visually verified
Finished 14: B-164 landed 47ae6f289598941c371eb3b9237253e4ddb6e6eb · not visually verified
Finished 15: B-165 landed c3ca374fca1dadf05b8364582cf9eccede1484b2 · not visually verified
Note: B-304 lane had build churn in ios/LeoFeatures/Package.resolved (xcodebuild/swift test); restored before land.
Note: 2026-10-27T03:30:44Z preflight sync merged stale local main (c55687eca); origin/main (812e5a9c4, leo-v0.25.0 with the agent browser) merged into autopilot as 724583189 after the B-306 runner found no agent-browser code. B-306 redispatched (not a fix attempt).
Note: B-308 verifier: Peekaboo bridge lacks Screen Recording and Accessibility permissions on Dionysus — GUI verification unavailable this run.
