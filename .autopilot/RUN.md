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
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 731b3d381194f4c76348c7bcc2e7dc4e77934767
  Dispatched: 2026-11-10T14:55:39Z
  Call: Mac only: the agent browser is a Mac WKWebView pane — VISION 1
  Call: Not contradicting D-733: it left the UA alone because it was irrelevant to the hyatt.com blank page (B-376); Chase gating on the Safari version is new evidence — VISION 4
  Call: Claim the installed Safari's major.minor (fallback Version/17.0), not a hardcoded constant — VISION 4
  Tokens: 14.6M in (14.2M cache read), ≥49.5k out, 152 requests

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
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 199d2fa562f70bd800d2caf5f3579536a7678657
  Dispatched: 2026-11-10T15:38:19Z
  Call: Fork PRs named bump/leo-* are never closed — AUTONOMY: CI config agent-decides; non-bump PR never touched
  Call: Closing never deletes a branch — criteria: "deletes nothing else"
  Call: Bump branches without strict X.Y.Z are skipped — conservative; no guessing at versions
  Call: Closing step also runs when the workflow updates an existing PR — idempotent
  Call: Platform: CI only, neither Mac nor iOS
  Tokens: 3.13M in (2.91M cache read), ≥29.2k out, 41 requests

Lane: B-386
  Branch: autopilot-lane/B-386
  Base: 7c6389fba81f04f1b3c3ab2d75a4e0fec64d5de9
  Tier: full
  State: verifying
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 3010fcffe5c68ff396e3508f1b5e39772a9703b9
  Dispatched: 2026-11-10T16:03:14Z
  Call: new `browser_user_agent` tool for existing tabs, plus an optional `user_agent` on `browser_tab_new` — explicit semantics, navigate unchanged (VISION 4)
  Call: empty string or whitespace-only clears; a missing or null `user_agent` fails `invalid_args` — a bare call can't wipe an override
  Call: values must be printable ASCII 0x20–0x7E, max 1024 characters — blocks header injection
  Call: both actions fail with `user_has_control` while the user drives, like `browser_tab_new`
  Call: popups inherit the opener's override (only when non-empty) — UA-gated login popups keep working (VISION 4)
  Call: no pane UI indicator and no `user_agent` field in `browser_tabs` — small scope cut
  Call: the schemas live in this repo, so no daemon change and no `~/.leo/agents/leo` edit — Mac only per D-756 (iOS is Out)

Finished 1: B-387 landed c4952d79b · not visually verified
Finished 2: B-389 landed 2fdce467e · not visually verified
Finished 3: B-385 landed 6af1bf283 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-385-1.png

Progress:
- Preflight: main already merged; inbox applied: created B-385 (bug), B-386, B-387 (features).
- Runners: B-385 d-33e7402b9bf1, B-387 d-45fee2bdf463 (leo implement role), parallel (independent: agent-browser UA vs bundled LEO_VERSION).
- B-387 landed c4952d79b (PR #356 head 57d20ed25 intact). Gap: Debug app has no bundled helper; verifier checked the tarball sha256 + `leo 0.81.0` instead.
- Inbox applied: B-389
- Lane finish (mid-run, my slip; harmless): removed landed B-387 branch; B-368 lane worktree is dirty (1 change), left in place.
- Runner: B-389 d-91e6580ccdef (light). Released B-387 panes.
- B-389 landed 2fdce467e: leo-bump.yml closes lower-version bump/leo-* PRs ("Superseded by #N"); 4 script test files pass; stubbed-gh dry run. Accepted risks: first failed gh close aborts the rest (next bump retries); `gh pr list --head` fork-name collision.
- B-385 landed 6af1bf283: agent browser UA now ends "Version/<installed Safari major.minor> Safari/605.1.15" (fallback 17.0). Verified in a standalone WKWebView (hyatt.com + chase.com/travel load); Chase sign-in redirect not reproduced end to end. Debug-app Open Browser failed with a daemon-connection error on both agents (unexplained, outside the diff) — shot shows that failure, not the UA.
- Runner: B-386 d-9f705c1e5e23 (full). Released B-385 runner pane.
