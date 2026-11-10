Status: running
Started: 2026-11-10T14:53:37Z
Budget: 20 items, until 2026-11-11T02:53:37Z
Digested-through: 0
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-387 → B-388 idea — LeoTemplateListTests manualRefresh flaky under load
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

Lane: B-385
  Branch: autopilot-lane/B-385
  Base: 3fdb60880d78463f0a856a21d3088d5c7d3b30b8
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T14:55:39Z

Lane: B-387
  Branch: autopilot-lane/B-387
  Base: 3fdb60880d78463f0a856a21d3088d5c7d3b30b8
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 052e2d3b9add200ffdbf0578a82252a09bf96915
  Dispatched: 2026-11-10T14:55:39Z
  Call: Merged PR #356 head via --no-ff merge, no cherry-pick — brief principle and B-364 precedent
  Call: Mac only — bundled daemon is a Mac app concern
  Tokens: 3.86M in (3.64M cache read), ≥16k out, 50 requests

Lane: B-389
  Branch: autopilot-lane/B-389
  Base: b27ca98019c76eb81399cf24fda342d2a8bb77ce
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T15:38:19Z

Finished 1: B-387 landed c4952d79b · not visually verified

Progress:
- Preflight: main already merged; inbox applied: created B-385 (bug), B-386, B-387 (features).
- Runners: B-385 d-33e7402b9bf1, B-387 d-45fee2bdf463 (leo implement role), parallel (independent: agent-browser UA vs bundled LEO_VERSION).
- B-387 landed c4952d79b (PR #356 head 57d20ed25 intact). Gap: Debug app has no bundled helper; verifier checked the tarball sha256 + `leo 0.81.0` instead.
- Inbox applied: B-389
- Lane finish (mid-run, my slip; harmless): removed landed B-387 branch; B-368 lane worktree is dirty (1 change), left in place.
