Status: running
Started: 2026-10-25T16:54:31Z
Budget: 20 items, until 2026-10-26T04:54:31Z
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
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-297
  Branch: autopilot-lane/B-297
  Base: e07d5ea238a4883d67df74b92f44c986a9161ae4
  Tier: full
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 945623be380d938a24a207c55bef493d7e9e9cb9
  Dispatched: 2026-10-25T16:57:03Z
  Call: In CI, skip and annotate instead of failing when no plain window can become key — AUTONOMY test-infra rule; P1 kept because a plain-window probe separates environment from regression
  Call: Don't force the runner active from inside the tests; runner setup is left as a follow-up — AUTONOMY test-infra rule
  Call: Keep the name `.requiresActiveHost` and its 5 call sites — smaller churn
  Call: Mac only — Mac/iOS rule (stated in commit messages)
  Call: Log checker keys on a `focus-gate-skip:` stderr marker, not Swift Testing's skip line — other suites also skip

Progress:
- Preflight: merged origin/main (791f4631b) into autopilot; applied 6 inbox entries (B-297 bug, B-298 add, B-299..B-302 ideas).
- B-297 runner dispatched: d-ea20172624fe (leo_dispatch implement → claude/sonnet, tier full). Brief passed as a file path (scratchpad brief-B-297.md).
