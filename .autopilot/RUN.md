Status: running
Item: B-049
Base: ac2b14c7d
Wip: none
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight: main merged (fast-forward to 0edccd0d8); inbox: 4 entries applied (B-049..B-052 added; B-051 blocked on Evan); B-048 promoted; no vetoes or new answers.
- Board sync (preflight): B-014: unknown status [deferred]
- B-048 verify: palette ⌘↩ OK (new tab, no full screen; shots B-048-2, -4); sidebar ⌘-click on the selected row DESELECTS and attaches nothing (shots B-048-6 → -7) → implementer fix. Note: live Last Activity re-sort moved real agent leo-vitals under the cursor during one ⌘-click; it only selected (no attach; client list unchanged). Row clicks now only with the sidebar filtered to autopilot-scratch.
- B-048 fix attempt 1 (e13738b88): deselect fixed and verified (shots B-048-1..3); ⌘-click attach not reproduced in the GUI, and the reviewer saw the new tests fail → sent back (fix round 1).
- B-048 fix round 1 (0604cc27f, LeoRowClickCatcher): the review found a HIGH (⌘-click on the Attach button double-attaches) and a MEDIUM (a double-click fires the row click more than once); the LOW about one monitor per row was dismissed (small row counts, clean lifecycle) → fix round 2.
- B-048 done (e13738b88 0604cc27f 5bd615a31): 1497 tests, lint clean; round 2 review clean (1 LOW dismissed: the ⌘⌥ double-click combination). Palette ⌘↩ verified; the ⌘-click attach was not visually verified (peekaboo). verify.md now has row-click notes.
- B-052 done (ee274b7f9): 1513 tests, lint clean, review clean. Shots B-052-1..5. Polish gap → B-053 (next run).
- B-050 (6875f2be7): review clean (1 LOW nit dismissed). Full suite at HEAD: 1534 tests, twice, with GhosttyAttachTabHostFocusTests/focusReportsArriveViewingFirst… failing deterministically (it passed at B-048/B-052) → fix round 1. The implementer's report of a setenv host crash didn't reproduce under runtests.sh.
- B-050 done (6875f2be7 14951a372): 1534 tests ×2, lint clean; reviews clean (the test-fix review's MEDIUM was dismissed: the test asserts editorPane != nil before isLoneStartTab, so it's a real guard). Shots B-050-1..4. The implementer's setenv/Zig Environ host crash is UNCONFIRMED: it happened only under load average ~178 from another project's xctest; 5+ later runs were clean.
- B-049 (a9dbf4e11): verified shots B-049-1 (no hover button), -2 (Start prompt), -4 (Start → attached in the start tab); Cancel verified (scratch still stopped, no tab). Review: MEDIUM incarnation dismissed (open-by-name is intended; attach is non-destructive); 2 LOWs (row identity across a re-sort, accessibility action) → fix round 1.
- B-049 done (a9dbf4e11 11930305f cf5025227): 1566 tests, lint clean; round 2 was accessibility modifiers only (checked against the review's prescription). No ready items left → finishing run. autopilot-scratch stopped (not deleted).
