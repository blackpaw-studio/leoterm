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
  State: landed
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

Lane: B-298
  Branch: autopilot-lane/B-298
  Base: 8b7365c47fbf56f060627099c69eede4fab77d96
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 4238419053afa5dfb17bb50b0c8bbdf8fb96d9d8
  Dispatched: 2026-10-25T18:09:58Z

Lane: B-154
  Branch: autopilot-lane/B-154
  Base: e8a81054f89faeaa09582ec3dad82797310bdf56
  Tier: light
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 5903b8213f54ca906d1a20f27e7b6bc07feed5ed
  Dispatched: 2026-10-25T19:00:21Z
  Call: Titled-style side-pane close glyphs centre on the sidebar header's line (sidebar + at 18 pt under the titlebar) — D-258, P1
  Call: The editor pane moves to the same line (14.5→18.5 pt), so the adjacent panes' glyphs align; this goes beyond the browser-only acceptance text and is easy to revert — D-258, P1
  Call: `sidePaneHeaderTopInset` is now a constant in every style, so titled styles no longer keep their own flush rows; hidden style gets the same value as before — D-536, P1
  Call: Mac only (side-pane headers are Mac UI) — Mac/iOS rule

Finished 1: B-297 landed 764fb1960d915550a38e77ad3431d9164c799b9d · not visually verified
Finished 2: B-298 landed 7ac647da70fd40ab12aa3a82bc7b04615613b9b6 · not visually verified

Progress:
- Preflight: merged origin/main (791f4631b) into autopilot; applied 6 inbox entries (B-297 bug, B-298 add, B-299..B-302 ideas).
- B-297 runner dispatched: d-ea20172624fe (leo_dispatch implement → claude/sonnet, tier full). Brief passed as a file path (scratchpad brief-B-297.md).
- B-297 landed 764fb1960 (6 commits, full review, 0 fix rounds). Decisions D-537..D-541. Follow-up outside repo: CI runner console setup so focus tests run instead of skipping.
- B-298 runner dispatched: d-d119a1ad868f (implement → claude/sonnet, tier light).
- B-298 landed 7ac647da7 (1 commit, 0 fix rounds, no calls). Runner saw one load flake (~37 load): LeoRuntimeMachinesTests.chatShowsNotConnectedOnlyWhileItsMachineIsDownAndReloadsOnReconnect asserts right after show(); passed on rerun.
- B-154 runner dispatched: d-56e91fa74a15 (implement → claude/sonnet, tier light).
