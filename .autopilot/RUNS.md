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
