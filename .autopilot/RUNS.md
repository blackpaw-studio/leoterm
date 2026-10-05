# Runs

## Run 2026-09-22 (16:49–19:20 EDT): 5 shipped, 0 blocked
Shipped
- B-002 Attention contract → leo agent. Accepted, then implemented as leo PR #210; not released (D-010, D-011)
- B-001 Attention model: 4e064d6f7 cb18a2a6c 013840a46 465676949 93e0c4f78 60cb67072 f378da52c a0899a492 190b70f4b c5540f3c7. Verified: screenshot (DEBUG fixture)
- B-008 Test flake + lint: d806f8ecf c3edaf507 a80bd0475. Test-only change
- B-006 Tab ↔ row linkage: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65. Verified: screenshots with autopilot-scratch
- B-003 File access (local + SFTP): 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4. Not visually verified (no UI); the E2E over localhost stopped at SFTP because it's disabled in sshd_config
Calls for veto: D-010–D-025
Queued: B-015, B-016, B-017 (ready next run)
Notes: the Jump test attached the debug app to real agent `brand` (view-only, since detached; its window stayed at 74x30). verify.md updated to prevent a repeat. The autopilot-scratch agent is deleted; its workspace dir ~/.leo/agents/autopilot-scratch is left in place.

## Run 2026-09-22 (19:20–23:30 EDT): 5 shipped, 0 blocked
Shipped
- B-015 Attention edge cases, plus leo's 3 live-testing clarifications: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e. Logic only, so not visually verified
- B-018 Dedupe attention on (boot, name, revision), with the heuristic removed (-126 lines): f2ed8537a. Logic only, so not visually verified
- B-016 Tab ↔ row polish: c25cf3523 82c835016 ab3f8c6ff 7d2b676e7 89ff485c9 79f8d61f2 7a3728f4f. Verified by screenshot B-016-1 (hover Attach no longer covers the name)
- B-017 File-access polish (socket dir, foreign sockets, SFTP errors, sanitizing): 97781e299 f8b3b4350 fb1bb244b 119697892 198da68e3 adb143d49 1c8ae5131 2f5f51b4d abf708a54. No UI
- B-004 Editor pane: 5980d43a6..676f70548 (19 commits). Verified by screenshot B-004-1 (Open File in Editor with a highlighted file); ⌘-click and remote were covered by tests only
Calls for veto: D-026–D-034. D-034 departs from the 3-attempt revert rule for B-004
Queued: B-019, B-020, B-021, B-022 (ready next run); B-005, B-007, B-009–B-012 ready
Tests: 1027 (the only failure is the known ConfigTests/errorsEmptyForValidConfig); swiftlint clean
Notes: leo merged the attention contract (PRs #209 and #210) to its main; it isn't released, and release is Evan's call. A macOS Screen Recording prompt for "leo" appeared on Dionysus; it was left untouched. Two implementer windows vanished and one lost its tracking mid-run; the work was recovered each time.

## Run 2026-09-23 (08:58–12:30 EDT): 5 shipped, 0 blocked
Shipped
- B-005 Per-agent workspace browser: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083. Verified by screenshots B-005-1..5 (row menu ▸ Browse Files, keyboard navigation, Return opens the file, ⇧⌘. shows dotfiles, sidebar collapses at 800 pt)
- B-022 Editor close gate, split width, wiring tests: 59ffb1fbd..bbcf58601 (14 commits). Verified by screenshot B-022-1 (half-width editor); the hung-save banner is covered by tests only
- B-020 Sanitize errors at one choke point, with an allowlist for invisible characters: ad0807785 796b0a2ec 8b6494d45 935b5a600. Error text only, so not visually verified
- B-021 Forwarded daemon socket in the short per-user dir: cda6610e8. No UI and no remote host
- B-019 Focus-order and ordered-relay tests: c92565ac3 ad537d10e 79d5d9375 6be661a48 24000299e. Test-only
Calls for veto: D-035–D-045. D-043 (B-020) and D-045 (B-019) depart from the 3-attempt revert rule, as D-034 did
Queued (ready next run): B-023 browser polish, B-024 editor close-wait polish, B-025 load flakes, B-026 selectors only after emoji, B-027 one tunnel per host + event-stream backoff, B-028 focus-test catch-up. Ready now: B-007, B-009–B-012
Tests: 1132 (the only failure is the known ConfigTests/errorsEmptyForValidConfig; LeoSyntaxHighlighterAdversarialTests flakes under load ~100 → B-025); swiftlint clean
Notes: leo_dispatch role review.security routed to codex/gpt-6-sol and failed every time ("Model metadata for `gpt-6-sol` not found"); security reviews ran on the Sonnet code-reviewer fallback. The plain review role on the same model worked. autopilot-scratch was created for verification and deleted afterwards; its workspace dir is left in place.

## Run 2026-09-23 (afternoon) — 4 shipped, 1 blocked
- B-028 focus test requires the catch-up: 256eeec38 1f924ee53 (not visually verified: test-only)
- B-026 hidden-bit channels in untrusted text closed with Unicode 18 tables + NFC: e5efc61b4 ac9539839 5a44072dd 03ac88d26 (not visually verified: error text)
- B-024 editor close-wait (lock only once committed; "Closing …" banner): 810596a0a 188851f1f 6a6be8646 7d10d709e 605d43e68 (not visually verified: auto mode refused peekaboo input)
- B-025 load-proof timing tests: cbc79e25c ba6e9d140 e37de61ee 1f96bee20 4eb3f5fa5 6e1267756 ba23155a9 (test-only)
- B-027 blocked after 3 fix rounds, reverted in 75f5b8eda; question: single instance per bundle?
- Calls: D-046 D-047 D-048 D-050 (D-049 reverted with B-027). New: B-029 B-030 B-031. Next: B-023, B-029–B-031, B-007.

## Run 2026-09-23 (evening) — 5 shipped, 0 blocked
- B-027 One tunnel per host: 10be4b608 6fec65c82 67de1e864 682f967c4 73109b6c3. Leo is single-instance per bundle (D-051); unsafe lock fails closed with an alert (D-053). Verified: B-027-1, B-027-2. Note: 10be4b608/6fec65c82 carry a 1 MB macos/default.profraw (untracked again in 682f967c4).
- B-030 Keep the selection on a refused keystroke: 31a72e027 0fd885414 ca7f95730 (D-055). Not visually verified (Open panel unreachable).
- B-034 DEBUG LEO_OPEN_FILE hook: 2c05c0b83 de2c47114 (D-056). Verified: B-034-1.
- B-031 Test flakes + truncated run: 05ec8fd2d 3e3859708 235748c7a b32c98cd4 40fdb2b8a (D-057). Also fixed parallel `xcodebuild test` hosts being quit. Test-only.
- B-023 Workspace browser polish: 30233456a aa5f8d878 39441c27d 36aee4e9e fac40cd67 b6a773954 f8c0c7c77 abd49da71 459098e6b (D-058, D-059, D-060). Verified: B-023-1, B-023-2.
- Calls: D-053 D-054 D-055 D-056 D-057 D-058 D-059 D-060. Evan's: D-051, D-052.
- New: B-032 (tests leak sockets into the real cache dir), B-033 (alert path), B-035 (Closing banner shot), B-036 (sidebar-feed flakes), B-037 (sidebar single-jump return).
- Review fallback: one review dispatch failed ("workspace routing discovery timed out"); Sonnet code-reviewer used for B-030 round 1.

## Run 2026-09-23 (night) — 5 shipped, 0 blocked
- B-007 Disconnected state: 7a2bf5da5 4f1cd16b7 0ed8a6b8f. A dropped stream, a dead tunnel or a failed wake check dims the rows and shows "Disconnected from <host>" with Retry (Agents ▸ Reconnect ⇧⌘R); the backoff reconnect is gone (D-061, D-062). Verified: B-007-1, B-007-2.
- B-037 Sidebar returns after a single big widen: 9307c661c (D-063). Verified: B-037-1/2/3.
- B-032 Tests no longer leak sockets into the real cache dir, and a bundle guard fails any run that does: f6a591e0a 41a653cfd aeb23c6b5 b03191132 (D-064). Test-only.
- B-036 Sidebar-feed flakes: 744ff0a71 fa3a8ff43 c4498f88e d32b2f060 0a9f77d2f b301bc587; 2020/2020 under 42× load; no product race (D-065). Test-only.
- B-029 Cleaner ZWJ trie + ICU drift test: 0747da6d4 cef6e152a (D-066). Not visual.
- Calls: D-061–D-066. New: B-038 (banner reason wrap, Choose Agent while disconnected), B-039 (test plist stubs), B-040 (weak AttentionRace test).
- Notes: one review dispatch failed ("workspace routing discovery timed out") → Sonnet code-reviewer for B-037. The first B-036 implementer hung 31 min in a PreToolUse hook; cancelled and re-dispatched. Tests: 1249 (known ConfigTests failure only); swiftlint clean.

## Run 2026-09-24 — 4 shipped, 1 blocked
Shipped
- B-038 Disconnected banner: one-line reason + tooltip; Choose Agent… visibly disabled while disconnected — 622783dad d1e8e149a (verified: B-038-1/2)
- B-033 "Leo can't start" alert: path-free sentence, one middle-truncated path line, Show in Finder — 7dd3ea2bf f93fab899 e2736fec7 (verified: B-033-1/2; Show in Finder unit-tested only, alert AX unreachable)
- B-009 Search: Agents ▸ Find Agent… ⌥⌘F, ranked fuzzy match with bold letters, Escape clears — 93a8c5b9f 823a717fb 03974e177 (verified: B-009-1/2/3)
- B-011 Row metadata: relative last-active time from identity-checked snapshots; task line when reported; no tokens/cost (not exposed) — a8b800d41 fd679d90a 8b5808341 (verified: B-011-1/2)
Blocked
- B-010 Sort and pin: event-driven last-activity ordering failed review 4× (namesake races); reverted f6dfc8aec. Question: re-scope to snapshot-only sort?
Calls: D-067 D-068 D-069 D-070 D-071 D-072 D-074 D-075 (D-073 reverted with B-010)
New: B-041 B-042 B-043
Next up: B-039, B-040, B-041, B-042, B-043, B-035, B-012

## Run 2026-09-24 (afternoon) — 5 shipped, 0 blocked
Shipped
- B-043 Row subtitle drops the template instead of "clau…"; a template that fits whole stays — bb7b9f81c 94685a65c (verified: B-043-1)
- B-041 Palette's disconnected row: the sidebar banner's one-line reason + tooltip — 40966ae59 (verified: B-041-2)
- B-042 Agent palette uses the sidebar's fuzzy matcher (name, then repo), bold letters — 9a355633e (verified: B-042-1)
- B-040 AttentionRace in-flight test now fails when boot reset breaks — 669c92d1f 892b6f18e fb92b79d9 (test-only; break-checked; 10/10 under load)
- B-039 Tests use in-memory defaults; bundle guard fails on any new test plist — 558a0585e a00d37484 b9cc40d4b (test-only; 0 new plists per run)
Calls: D-076 D-077 D-078 D-079 D-080
New: B-044 (delete 31k old test stubs — needs Evan)
Next up: B-035, B-012; still blocked: B-010 (re-scope?), B-013, B-014, B-044
Tests: 1360 (known ConfigTests failure only); swiftlint clean.

## Run 2026-09-24 (evening) — 3 shipped, 1 blocked
Shipped
- B-010 Sort and pin (re-scoped): Last Activity from identity-checked /state snapshots only; Sort By ▸ Last Activity / Name; Pin (⌥⌘P) into a Pinned section; collapsible sections per host — dfe6f29e8 (verified: B-010-1/2)
- B-012 Cold start: measured, list lands ~120 ms after the sidebar (+500–523 ms); no cache needed; DEBUG LaunchTiming kept — e45d323fb 826e921ee (measurement only)
- B-035 Editor "Closing…" banner captured during a held save — no code (verified: B-035-2/4/5; recipe in verify.md)
Blocked
- B-013 Surfaced files: daemon contract approved by Evan via leo (being built). App side's auto-open failed review 4× (races); reverted f3e8d36b3. Question: drop auto-open, badge + ⌥⌘O/menu only?
Needs Evan to do
- B-044 Trash the Leo*Tests* preference stubs (one-line command in BACKLOG)
Calls: D-081..D-084 (Evan's answers), D-085, D-087 (D-086 reverted with B-013)
New: B-045 (Closing banner blanks the editor header; next run)
Next up: B-045; blocked: B-013, B-044; deferred: B-014
Tests: 1393 (known ConfigTests failure only); swiftlint clean.

## Run 2026-09-24 (evening) — 2 shipped, 0 blocked
- B-045 Editor Closing banner: 10ec5d41f 350a88ecc f778624b5. Header stays, banner is a leading full-width row; root cause was the banner's dirtyRect fill overpainting the header (macOS 14 no-clip). Verified: B-045-2.png.
- B-013 Surfaced files, badge-only: 70a2b21e8 eed22646d 813d4f335 263040196. Row badge + Surfaced Files menu + ⌥⌘O; no auto-open. Verified: B-013-1..4 (DEBUG fixture on a temporary autopilot-scratch, deleted).
- B-044 marked done (Evan trashed the stubs).
Calls: D-088, D-089 (Evan), D-090, D-091
Board sync: B-014 `deferred` has no board column (2 non-fatal warnings)
Next up: B-046 (next run); deferred: B-014

## Run 2026-09-24 (night) — 1 shipped, 0 blocked
- B-046 Surfaced files keep `at` order through a partial /state merge: a91e50296 a70d51027. Event-only files placed by `at`; an all-malformed full baseline clears stale live files; cleared incarnations free their LRU slot. Not visually verified (index-only; unit tests incl. ⌥⌘O routing).
Calls: D-092
Board sync: B-014 `deferred` has no board column (2 non-fatal warnings)
Next up: none ready; deferred: B-014
Tests: 1463 (known ConfigTests failure only); swiftlint clean.

## Run 2026-09-24 (evening) — 1 shipped, 0 blocked
- B-047 One tab per agent — d403a2c9a. Row click / palette choice focus the agent's open tab (other window comes forward); ⌘-click, ⌘↩, "Attach in New Tab" force a new one; tab-count glyph removed. Verified: B-047-1, B-047-2 (row click reuse across windows). Palette ⌘↩ not visually verified → B-048.
- Calls: D-093 (blank start tab closes after jumping; ⌘↩ hint in palette search field; placeholder panes fill in place).
- Next up: B-048 (ready next run).

## Run 2026-09-28 — 4 shipped, 0 blocked by the run (B-051 waiting on Evan)
- B-048 Sidebar ⌘-click: e13738b88 0604cc27f 5bd615a31. Palette ⌘↩ was already correct. The ⌘-click deselected the row and never attached. Fixed with a required List selection plus `LeoRowClickCatcher` (clicks read from mouse events, so rows work in non-key windows); double-click and the Attach button act exactly once. Verified: B-048-1..3; the ⌘-click attach itself was not visually verified (peekaboo modifier clicks are unreliable), so tests only. 2 fix rounds.
- B-052 Attach tabs titled with the agent's name: ee274b7f9. Verified B-052-1..5 (title, Change Tab Title… wins and clears, restart, reattach).
- B-050 First attach fills the start-page tab: 6875f2be7 14951a372. Also fixed D-093's blank-tab close, which never fired (the check used pane refs). Verified B-050-1..4. 1 fix round (the new integration tests showed windows that stole key status from another suite).
- B-049 Click a row to open; Start prompt for stopped agents: a9dbf4e11 11930305f cf5025227. Verified B-049-1..4 plus Cancel. 2 fix rounds (row identity across a re-sort; accessibility).
- Inbox: B-049..B-052 added; B-051 blocked (Needs Evan: daemon contract change + leo release timing).
Calls: D-094, D-095, D-096, D-097
New: B-053 reattach after a restart refills the exited tab (ready next run)
Unconfirmed: the implementer saw a test-host crash (Zig Environ, tunnel tests' setenv) only under heavy load from another project's tests; not reproduced in 5+ runs.
Board sync: B-014 `deferred` has no board column (non-fatal warnings)
Tests: 1566, all pass; swiftlint clean.
Next up: B-053 (next run); blocked: B-051; deferred: B-014

## Run 2026-09-28/29 — 3 shipped, stopped early (incident)
- Shipped: B-054 (3a2205a65) host-aware template lists; B-055 (4134ce4f4 6fb5c8c8d) no tab bar, one content area per window; B-056 (b9e6ec48a 9d4b8033b b40d3a4bb) live surface pool N=4.
- Calls: D-102, D-103, D-104, D-105, D-106, D-107, D-108, D-109, D-110, D-111.
- Stopped early: during B-057 verification a blind keystroke sequence in a fresh debug build started and attached the real agent alfred-itunes-dj. It was detached within seconds, not stopped (Evan decides).
- B-057 left unlanded (2 review HIGHs + not visually verified). Next run: fix, re-review, re-verify.
- Filed: B-061 (inject template fetch in tests), B-062 (tab-era renames + review cleanups), both ready (next run).

## Run 2026-09-29 (stopped early at Evan's request, to release)
Fixed: B-063 sidebar order churn (d904cf393, streak hysteresis; tests only), B-064 sidebar top spacing (ed551bcca; shot B-064-1)
Shipped: B-057 Terminals sidebar rows (e5f683b24; both prior HIGHs fixed; shots B-057-9..11)
Calls: D-112..D-124 (veto-able). Filed: B-067..B-075 (next run).
Notes: B-057 runner used 3 fix rounds against a budget of 2; test runner needs env presets (verify.md, B-072); landed lanes' worktrees kept (untracked build files); Board sync: B-014 unknown status [deferred].

## Run 2026-09-29 22:22Z → 2026-09-30 02:20Z (early stop)
🛠 leoterm autopilot — 5 shipped, 0 blocked (early stop)
Shipped
• B-066 ⌘T collision — ⌘T is New Terminal alone; start screen hints ⌘O for Choose Agent… (930a1f331) · light
• B-067 Terminals row scrolls into view on create/select/filter-clear (c905bd4c9 f8135ef58) · light
• B-068 same-titled shells read "~", "~ (2)" (59b259e37 677060e4f) · light
• B-069 start-screen New Terminal button (7ba7c4400) · light
• B-070 window reads "👻 Ghostty" after the last shell closes (01fb138dd) · light
Calls: D-125..D-139
Stopped: B-071 runner returned Error (harness forced hand-back while its fix-round verifier ran). Reviews on bc8aae9f1 approved; only verify missing. Left unlanded on autopilot-lane/B-071 (verifying, Fixes 1) for a re-verify at next preflight.
Filed next run: B-076..B-083 (B-082 is a pre-existing split-close orphan bug). Inbox: 3 bugs queued mid-run.
Lanes: landed lanes B-054..B-070 not removed (untracked build output); orphan verifier test host was running in lanes/B-071.

## Run 2026-09-30 02:53Z → 18:02Z
🛠 leoterm autopilot — 3 fixed, 14 shipped, 1 blocked
Fixed
• B-084 sidebar width remembered across launches (2dc23544c) · full
• B-085 window always appears on launch (feb25ef04) · full
• B-086 no tiny window on first attach (610f7170c) · full
Shipped
• B-071 ⌘Z of a split close no longer kills a busy hidden shell (8cede5a7f) · full
• B-072 libghostty copies environ; test host no longer crashes (668489764) · full
• B-074 hidden-titlebar band fixed (15a4fb832) · light
• B-075 search field doesn't grab focus on launch (dcff3a923) · light
• B-076, B-078 test tightening (98f02585d, 442cac897; not visually verified) · light
• B-079 Terminals row label polish (b7bff26e4) · light
• B-080 start-screen hints follow live keybinds (518efbdc4) · light
• B-081 sidebar lands on selection/top after last shell closes (7c0ac3f91) · light
• B-082 closing a row's pane beside a split hands the row on (2c957c192) · full
• B-083 undo-manager re-entry crash + test polish (44bc4c74a; not visually verified) · light→full
• B-061 template fetch injected in tests (55944084a; not visually verified) · light
• B-062 tab-era renames, one agent predicate (232172574; not visually verified) · full
• B-065 sidebar footer: New Terminal + Quick Terminal (c8804dee3) · full
• B-073, B-077 done without a lane (verify.md/runtests.sh)
Escalated to the hard implementer: B-082 (plan Difficulty: hard)
Calls: D-140..D-211 (veto-able)
Needs you
• B-058 held on autopilot-lane/B-058 (shelve refused: untracked build output) — runner timed out at 3h mid fix round; 1 blocking item left (on-screen row reveal fires once). Resume next run? I'd pick yes.
Filed next run: B-087..B-114 (incl. bugs B-090, B-092, B-097, B-109; B-110 cross-window drag can free a shell without asking)
Next up: B-059, then B-087+
Interim updates: 3 posted, through item 15
Lanes: landed lanes kept (untracked build output); Untracked-left in main worktree and lanes/B-071
Board sync: 1 failure (B-014 unknown status [deferred])
Merge when happy: git -C /Users/evan/.leo/agents/leoterm merge autopilot

## Run 2026-09-30T18:19:05Z → 2026-10-01T06:34:33Z
🛠 leoterm autopilot — 3 fixed, 11 shipped, 1 blocked
Fixed
• B-090 Sidebar hidden at launch stays hidden (980ec80b4, 8e7cd5d02) (verified: screenshot) · light
• B-092 Fast quit→reopen leaves exactly one Leo; pid-in-lock + kqueue wait (85ca7d75b, 712e5b926, 8094e6416) (verified: screenshot, 12/12 race) · full
• B-097 Reset Window Size keeps the configured size on a start screen (d1161c857, 88c4d4088) (verified: screenshot) · light
Shipped
• B-115 In-app updates on; debug builds check but never install (1616be959…10bb68570) (verified: screenshot) · full
• B-087 Palette-chosen split keeps cursor focus (09f7d4de2) (verified: screenshot) · light
• B-088 Close confirms name the pane/row (c606e4f2d) (verified: screenshot) · light
• B-089 Sidebar width persists only on its own divider move (…e41196534) (verified: screenshot) · full
• B-091 Content keeps ≥450 pt; sidebar gives way (25f7b4bd7, 42ecc4794) (verified: screenshot) · light
• B-093 Hidden-launch window replacement fixes (…5f7b9c4fb) (verified: screenshot) · full
• B-094 Launch-placeholder test hardening (17f1d88b6) (not visually verified: test-only) · light
• B-095 Dock reopen / fallback New Window: no palette flash (13d56313c) (verified: screenshot) · light
• B-096 B-086 test now fails without its guard (0bc16b549) (not visually verified: test-only) · light
• B-098 Environ OOM test; found a std 0.16.0 createPosixBlock bug (…e0c6a8db1) (verified: screenshot) · full
• B-099 Sidebar scroll flake fixed: "No matches" overlays the list (…291915f91) (verified: screenshot) · full
Calls I made — reply "veto D-0xx" to undo
• D-218 relaunch retries ≤5 s for the dying copy's lock release
• D-221 unset auto-update → Sparkle's prompt; one-time defaults reset
• D-228 `Close “<name>”?` copy
• D-235 content minimum 450 pt
• D-237 resize-clamped sidebar regrows on widen (narrows my own D-231 — landed, flagged)
• D-251 "No matches" is an overlay on the list
Needs you — reply "B-0xx: <answer>"
• B-109 couldn't reproduce: closed pane's shell lives only the 5 s undo window. "B-109: close" or more detail. Pin tests on autopilot-shelved/B-109.
• Orphaned test fixture pid 22743 (fake_ssh.py) still running — kill when convenient.
• autopilot-lane finish removed nothing: every landed lane (B-054…B-115) has untracked build leftovers (profraw, scratchpad/, zig-out) so it refuses. Lanes need a gitignore or finish should ignore untracked output.
• Shared xcframework under .git/autopilot/shared predates B-098's src/ change (filed as polish).
• Two runners were cut off by the harness mid-round and one round died on an expired login; I finished them from the orphaned agents' reports rather than stopping the run.
Ideas parked — "/feature B-0xx" to spec one
• B-058 Splits inside the content area
Next up: B-100, B-101 (+35 polish items queued for next run)
Interim updates: 2 posted, through item 10
Worktree: /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree
Board: https://github.com/orgs/blackpaw-studio/projects/5
Merge when happy (from your default branch): git -C /Users/evan/.leo/agents/leoterm merge autopilot

## Run 2026-10-01T16:01Z → 2026-10-02T04:10Z (deadline)
🛠 leoterm autopilot — 10 shipped, 1 blocked
Shipped
• B-100 Hidden titlebar: side-pane headers take the sidebar's inset (7c9cb2d1f…) (verified: screenshot) · light
• B-101 Launch-focus: Tab reaches search in real launch order (c640ac20b f09c93245) (not visually verified: test-only) · light
• B-102 Menu shortcut guards catch bare O/T, cover every live item (1f32b5966) (not visually verified: test-only) · light
• B-103 Calm-scroll tests park mid-list, assert identity (396984a56) (not visually verified: test-only) · light
• B-104 Shortcut hints spell F-keys; disconnected tooltip reads Reconnect live (3612df84d 83224b8a9) (verified: screenshot) · light
• B-105 Last-shell close lands only if Terminals was on screen; true top (5ce958ac9…) (verified: screenshot) · light→full
• B-147 Shared libghostty rebuilt after B-098 (no code change) · light
• B-106 Selected row highlight after last shell closes — didn't reproduce; regression test (6b08d7233 c1b36b866) (not visually verified: test-only) · light
• B-107 Closed row hands on to upstream's next-focus pane, same turn (0ede659d9…) (verified: screenshot) · full
• B-108 Undo-restored split panes get their Leo handle back (f8878eeca…) (verified: screenshot) · full
• B-147 built before B-106 (shared build was stale for every verify)
Calls I made — reply "veto D-0xx" to undo
• D-262 New Terminal may hold only ⌘T (refines D-177)
• D-268 disconnected Choose Agent… tooltip reads Reconnect's live shortcut
• D-270 last-shell close doesn't move a scrolled-off list (refines D-187)
• D-276 closed row → upstream's next-focus pane (refines D-191)
• D-280/281 restored panes come back as plain splits via Leo's own handle
Needs you — reply "B-0xx: <answer>"
• B-110 runner timed out (3h52m) mid fix round 2; 15 commits on autopilot-shelved/B-110. I'd pick: retry next run from that branch.
• B-110's last implementer may have outlived the stop (its lane worktree is removed).
• finish still can't remove dirty landed lanes (untracked profraw/scratchpad/zig-out).
Ideas parked — "/feature B-0xx" to spec one
• B-058 Splits inside the content area
Next up: B-111, B-112 (+2 queued /feature items, 26 polish items for next run)
Interim updates: 2 posted, through item 10
Worktree: /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree
Board: https://github.com/orgs/blackpaw-studio/projects/5
Board sync: 1 failure kind (B-014 unknown status [deferred]) (see RUN.md)
Merge when happy (from your default branch): git -C /Users/evan/.leo/agents/leoterm merge autopilot

## Run 2026-10-03T23:55Z – 2026-10-04T11:25Z

🛠 leoterm autopilot — 20 shipped, 0 blocked (+3 closed with no code change)
Shipped
• B-177 Terminals row context menu — Show, Split Right, Split Down, Rename…, Close; custom names stick over OSC titles (verified: screenshot) · full
• B-176 New Agent in Worktree… on agent rows — prefilled sheet, required branch, spawns via the host's daemon (verified: screenshot; never submitted) · full
• B-118 Single-instance only waits on a pid that is a copy of this bundle (verified: screenshot) · full
• B-128 Update permission asked once, in the pill only (verified: screenshot) · full
• B-129 Debug builds never offer auto-install updates (verified: screenshot) · light
• B-130 App menu reads About Leo (verified: screenshot) · light
• B-113 Sidebar button bar: one "Quick Terminal" name, new glyph, shared button actions (verified: screenshot) · full
• B-112 Template-runner test isolation (verified: screenshot) · full
• B-114 Test runner tracked at macos/scripts/leo-runtests.sh; lists parameterized failures (not visually verified) · light
• B-111, B-116, B-119–B-127 docs, tests, logging and naming polish (not visually verified) · light
• B-117, B-137, B-169 closed: verify.md fix / already satisfied by B-114
Calls I made — reply "veto D-0xx" to undo (D-284–D-343)
• D-293 Worktree mode reuses the New Agent sheet
• D-307 Quick Terminal glyph menubar.arrow.down.rectangle (refines D-207)
• D-311 runtests.sh moves into the repo (scratchpad copy retired)
• D-336 Update question only in the pill, never Sparkle's alert
Needs you
• B-177: no shell row survives an app restart today (window restoration off), so title persistence is proven by a round-trip test only
• B-176 verify repointed autopilot-scratch at nomad-openvpn-deploy-action (restored), briefly made+deleted leo-claude-autopilot-scratch, left clone ~/.leo/agents/nomad-openvpn-deploy-action
• B-111's first runner handed back mid-build (harness); I re-dispatched instead of shelving
• B-110 still blocked from last run; B-058 lane held
• Your 2 /issue bugs (errored agents, ssh in terminals) apply at next preflight, first
Ideas parked — "/feature B-0xx" to spec one
• B-058 Splits inside the content area
Next up: B-131, B-132, B-133 (+41 polish next run)
Interim updates: 4 posted, through item 20
Worktree: /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree
Board: https://github.com/orgs/blackpaw-studio/projects/5
Board sync: B-014 unknown status [deferred] every sync (see RUN.md)
Landed lanes B-128/129/130/176/177 not removed (untracked build output)
Merge when happy (from your default branch): git -C /Users/evan/.leo/agents/leoterm merge autopilot

## Run 2026-10-05 (cap 5)
🛠 leoterm autopilot — 4 fixed, 1 shipped, 1 blocked
Fixed
• B-220 ssh in in-app terminals — Contents/MacOS/ghostty now links to the Leo executable, so the shell-integration ssh wrapper finds it (verified: screenshot) · light
• B-221 CI never ran .github/scripts/leo tests — new run-tests.sh runs every test_*.sh from leo-ci.yml, with a guard test (not visually verified: CI only) · light
• B-222 sparkle-key-check hid plist errors — parse/unreadable/missing-key errors now surface PlistBuddy's output (not visually verified: CI only) · light
Shipped
• B-131 Focus test hardening — Escape via commit(.cancel); both palette tests re-require key window (not visually verified: test-only) · light
Calls I made — reply "veto D-0xx" to undo
• D-344/345 relative ghostty→Leo symlink via build phase; CFBundleExecutable and upstream scripts untouched
• D-346–348 script tests run in leo-ci.yml; YAML guard uses /usr/bin/ruby; docs/leo/ci.md updated
• D-349–351 separate network-free plist-error test; unreadable check; "Does Not Exist" match with raw-output fallback
• D-352/353 focus tests: key-window re-check; Escape through panel.keyDown
Needs you — reply "B-0xx: <answer>"
• B-219 sidebar "errored" is a leo daemon bug: attention hooks are dropped after /clear changes session_id (leo, leoterm, blackpaw-games-site stuck ~35h). Send the leo agent a bug + failing Go test, add Swift pins, no app-side hiding? I'd pick yes; you release/restart the daemon. Shelved: autopilot-shelved/B-219 (empty).
• calls in shelved work, not logged: B-219 daemon-bug routing; tests-only pins
• Lane cleanup: 73 lane worktrees on disk; landed ones aren't removed because each holds untracked zig-out/profraw leftovers. Want me to trash those leftovers so finish can prune them?
Ideas parked — "/feature B-0xx" to spec one
• B-058 Splits inside the content area
Next up: B-132, B-133, B-134
Worktree: /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree
Board: https://github.com/orgs/blackpaw-studio/projects/5
Board sync: 1 failure (B-014 unknown status [deferred])
Merge when happy (from your default branch): git -C /Users/evan/.leo/agents/leoterm merge autopilot
