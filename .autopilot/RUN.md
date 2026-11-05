Status: running
Started: 2026-11-05T23:52:44Z
Budget: 20 items, until 2026-11-06T11:52:44Z
Digested-through: 0
Filed: 0/3 bugs, 0/5 ideas
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
  State: building
  Fixes: 0
  Wip: 3d2b0d723
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-31T19:14:00Z
  Tokens: 3.26M in (3.05M cache read), ≥22.5k out, 41 requests
  Call: Keep the minimal Zig C export `ghostty_config_key_is_binding_for_action` instead of a Swift-only workaround — AUTONOMY (Zig minimal) + VISION (menu keys reflect real keybinds)
  Call: Treat chained and leader bindings as "not this action" — VISION (no shortcut beats a wrong or shared one)

Progress:
- Preflight: main merged (a24754cb4); inbox applied: created B-339..B-349 (11 entries). B-334 recovered (lane clean at 3d2b0d723, no new wip) as first pick, tier full. Lanes B-233, B-332 still unlanded with no block (items done) — left in place.
