Status: running
Item: B-025
Base: 605d43e68e4137974561eea8fcbb8227a0be9406
Wip: none
Untracked-left: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main already merged (2cc6f5f75). No inbox, vetoes, or answers. Promoted B-023 B-024 B-025 B-026 B-027 B-028. Order this run: B-028, B-026, B-027, B-024, B-025.
- B-028: built 256eeec38 (1132 tests). Test-only → not visually verified. Review: 1 MED (count wait + catch-up can each spend 30 s, so the 1-min limit fires before the #require) → attempt 1 (d-f466ed64979e#2).
- B-028 done: 256eeec38 1f924ee53 (1132 tests). Re-review MED/LOW dismissed (needs a >40 s main-queue stall and still fails; a late arrival is harmless).
- B-026: built e5efc61b4 (1134 tests). Error text only → not visually verified. review.security (codex route works today): 2 MED (‼️ loses selector; FE0F after emoji-default base is a hidden bit) + LOW (Indic ZWNJ without virama) → attempt 1 (d-d1c14708b8c2#2); D-046.
- B-026: attempt-1 fix ac9539839 (1135 tests). Re-review: 2 HIGH (Arabic ZWNJ after a non-forward-joiner; ZWJ between non-RGI emoji — both B-020 rules) + 2 MED (cross-script Indic ZWNJ; optional keycap FE0F) → attempt 2 (d-d1c14708b8c2#3): RGI ZWJ table, Joining_Type, same-script virama, canonical keycaps.
- B-026: attempt-2 fix 5a44072dd (1135 tests; RGI ZWJ + ArabicShaping 18 data in LeoUnicodeData.swift). 3rd review: MED (Indic ZWNJ before an independent vowel), MED pre-existing (no NFC), LOW (longest-match cost, bounded → dismissed) → attempt 3, the last (d-d1c14708b8c2#4).
- B-026 done: e5efc61b4 ac9539839 5a44072dd 03ac88d26 (1136 tests). 4th review.security clean. D-046, D-047. LOW → B-029.
- B-027: built 77957fcdf (1145 tests). No remote host → not visually verified. review.security: 3 HIGH (probe/unlink race; ECONNREFUSED ambiguous; reap SIGTERMs a sibling, pre-existing) + 2 MED (pid reuse; blocking probe) → attempt 1 (d-a67f56b72e3c#2): flock ownership, D-049.
- B-027: attempt-1 fix 9bdf7cb22 (1154 tests). Re-review: 2 HIGH + 1 MED, all mixed-version (pre-B-021/pre-D-049 copies running at once): the legacy-record SIGTERM gets fixed (never signal legacy records); the pre-lock cache-path HIGH and the legacy-probe MED are dismissed as an upgrade-overlap window. LOW (lock mode) fixed → attempt 2 (d-a67f56b72e3c#3).
- B-027: attempt-2 fix 07e8aaa59 (1157 tests). 3rd review: HIGH (single orphan record for all hosts, pre-existing) + MED (reap does not confirm exit) → attempt 3, the last (d-a67f56b72e3c#4).
- B-027 blocked: 4th review found 2 HIGH (Retry cannot recover a kept lock; ssh started before its record) + MED + LOW after attempt 3 (93032ed6e). Reverted 77957fcdf..93032ed6e in 75f5b8eda. Question: single instance per bundle? D-049 reverted.
- B-024: built 810596a0a 188851f1f 6a6be8646 (1141 tests; DEBUG LEO_SLOW_SAVE_SECONDS hook). review: HIGH (overlapping closes reset the shared lock → edits discarded) + MED (slow-save fixture can write after abandonment) → attempt 1 (d-b9a2794fc853#2). Visual check running in parallel.
- B-024: visual check blocked: auto mode refuses peekaboo type/press/click, so the Open File dialog could not be submitted → not visually verified. Attempt-1 fix 7d10d709e (1143 tests). Re-review: HIGH (a DEBUG fixture write already in flight lands after abandon) dismissed (DEBUG-only; inherent to any in-flight write, per B-022); 2 MED (async lock lets one keystroke through; cancellation test racy) → attempt 2 (d-b9a2794fc853#3).
- B-024 done: 810596a0a 188851f1f 6a6be8646 7d10d709e 605d43e68 (1145 tests). 3rd review: LOW only → B-030. D-050. Not visually verified.
- B-025: built cbc79e25c ba6e9d140 e37de61ee 1f96bee20 (1145 tests; 10/10 under 28× yes load; each proven by breaking what it guards). New flake seen: LeoSidebarFeedFixTests/sseRefreshTask… → B-031. Review: HIGH (until swallows cancellation) + 2 MED (fatalError on missing ICU symbol; .dispatch grace timer uncovered) + LOW → attempt 1 (d-a16546fcc61e#2).
