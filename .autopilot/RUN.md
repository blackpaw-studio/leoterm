Status: running
Item: B-027
Base: 03ac88d2631d59e5277923e6cff2e8f0b4af1d06
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
