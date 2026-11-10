Status: finished
Started: 2026-11-10T18:17:29Z
Budget: 20 items, until 2026-11-11T06:17:29Z
Digested-through: 0
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-391 → B-392 idea — Clearer error than WebKit's "no longer reachable" for a hung browser_eval
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

Lane: B-390
  Branch: autopilot-lane/B-390
  Base: a8da19c74da732d2a2a4034c49dfae1b653998f6
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: b715e557b5833b0161bff6d4ce48ac222f09690b
  Dispatched: 2026-11-10T18:18:26Z
  Call: "spinning icon" = the leading state symbol (the trailing indicator was already clickable and is hidden for an indeterminate task) — D-766
  Call: the symbol opens Tasks for any row with a task, succeeded included, to match the Show Tasks VoiceOver condition — D-766
  Call: trailing indicator, Show Tasks VoiceOver action and indeterminate-task fallback unchanged — D-746
  Call: line-2 `.help` tooltip (the B-381 risk) is now plain text with no click route — D-766
  Call: Mac only; iOS has no task-list tap target — VISION 6, repo AGENTS.md
  Tokens: 8.07M in (7.77M cache read), ≥37.8k out, 89 requests

Lane: B-391
  Branch: autopilot-lane/B-391
  Base: a8da19c74da732d2a2a4034c49dfae1b653998f6
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 1
  Reviewed-tip: a2742572f4ffce98a1cff54c3b5d746f36c60f78
  Dispatched: 2026-11-10T19:15:59Z
Finished 1: B-390 landed 281d9d55e · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-390-6.png
  Call: Free the queue only on the daemon's existing cancel; no app-side eval timer — VISION 5 (a bounded error path, not a reconnect loop)
  Call: Fix both the serial gate (any page call that ignores cancellation) and the WebKit page `run` (the actual leak) — AUTONOMY implementation approach
  Call: Mac only: the agent browser is a Mac WKWebView feature; the gate sits in LeoKit but only the Mac uses it, so no iOS backlog item — repo AGENTS.md parity rule
  Call: Added LeoOnce.swift as a shared first-wins helper for the gate and the page `run`; navigation test waits on web-view title/loading state instead of evals — implementer deviations
Finished 2: B-391 landed 14f165b3f · not visually verified
  Tokens: 32.6M in (31.8M cache read), ≥127k out, 245 requests

Progress:
- Preflight: main already merged; no new bump/leo-* PR (open #343/#337/#336 are older than 0.81.0); inbox applied: created B-390, B-391 (bugs).
- B-390 light (UX click-target move, D-766 supersedes D-745); B-391 full (async/queue concurrency). Independent: sidebar row vs browser bridge.
- Runners: B-390 d-5ab5c37e8363 (light), B-391 d-fb904012c29a (full), parallel. Wake timer b2nswctv7.
- B-390 landed 281d9d55e: Tasks popover now opens from the leading state symbol; line-2 click selects the row. GUI-verified on autopilot-scratch (shots 4, 6). Not verified: symbol hover tooltip, Show Tasks menu path.
- B-391 ready at adb4ea287 (concurrency review full, suites pass) but stale: B-390 landed after Integrated-at 260a53711. Re-verify round 1 dispatched.
- B-391 landed 14f165b3f after re-verify 1 (concurrency delta review clean; 4253 Mac + LeoKit tests pass). Verifier in round 1 reproduced on a local page: after each timeout browser_tabs/eval answered ≤55 ms. Daemon cancel at 30 s relied on (leo internal/clienttools/calls.go:161), not re-checked live.
