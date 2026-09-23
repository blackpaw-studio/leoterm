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
