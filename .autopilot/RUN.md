Status: running
Started: 2026-11-05T23:52:44Z
Budget: 20 items, until 2026-11-06T11:52:44Z
Digested-through: 0
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-334 → B-350 idea — Edit menu ignores key-table rebinds of ⌘C/⌘V
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

Lane: B-334
  Branch: autopilot-lane/B-334
  Base: c18a40f8e34f237f97655f7bb0da70ad7f7ef7c4
  Tier: full
  State: landed
  Fixes: 0
  Wip: 3d2b0d723
  Reverifies: 0
  Reviewed-tip: c75a2c155778eaae1e1e9e79f22fe44aabc156a0
  Dispatched: 2026-11-05T23:56:00Z
  Tokens: 7.55M in (7.17M cache read), ≥40.4k out, 91 requests
  Call: Keep the minimal Zig C export `ghostty_config_key_is_binding_for_action` instead of a Swift-only workaround — AUTONOMY (Zig minimal) + VISION (menu keys reflect real keybinds)
  Call: Treat chained and leader bindings as "not this action" — VISION (no shortcut beats a wrong or shared one)
  Call: Mac only: iOS has no Edit-menu key equivalents — Mac/iOS parity rule
Lane: B-338
  Branch: autopilot-lane/B-338
  Base: 64a82ce1e5afed45ec5b34fbeaa7d82b6416912c
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-06T00:24:00Z
  Tokens: 3.15M in (3.02M cache read), ≥11.2k out, 38 requests

Lane: B-339
  Branch: autopilot-lane/B-339
  Base: d99f557640a2ab3c27a9fef210e8eea91f1017c2
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-06T00:31:00Z

Finished 1: B-334 landed e54d3a530f4393a55d176576ed2202b971a933a3 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-334-1.png
Finished 2: B-338 blocked

Progress:
- Preflight: main merged (a24754cb4); inbox applied: created B-339..B-349 (11 entries). B-334 recovered (lane clean at 3d2b0d723, no new wip) as first pick, tier full. Lanes B-233, B-332 still unlanded with no block (items done) — left in place.
- B-334 runner: leo dispatch d-1bd4c6d2f725 (implement, pane %250).
- B-334 landed e54d3a530 (review general full; verify pass; 4014 tests green). Self-filed B-350 idea.
- B-338 runner: leo dispatch d-1ec0acf6fe5c (implement, pane %255), light, iOS only.
- B-338 blocked: could not reproduce (passes locally 10/10 and on hosted CI run 41953539577); shelved to autopilot-shelved/B-338 (no commits).
