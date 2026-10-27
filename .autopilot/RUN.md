Status: running
Started: 2026-10-27T01:43:03Z
Budget: 20 items, until 2026-10-27T13:43:03Z
Digested-through: 6
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
Note: B-304 lane had build churn in ios/LeoFeatures/Package.resolved (xcodebuild/swift test); restored before land.
Note: 2026-10-27T03:30:44Z preflight sync merged stale local main (c55687eca); origin/main (812e5a9c4, leo-v0.25.0 with the agent browser) merged into autopilot as 724583189 after the B-306 runner found no agent-browser code. B-306 redispatched (not a fix attempt).
Note: B-308 verifier: Peekaboo bridge lacks Screen Recording and Accessibility permissions on Dionysus — GUI verification unavailable this run.
