Status: running
Started: 2026-11-15T01:48:53Z
Budget: 20 items, until 2026-11-15T13:48:53Z
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

Lane: B-110
  Branch: autopilot-lane/B-110
  Base: be2129990578913aa7929e6d8d253a33eb3c76a8
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T01:51:24Z

Lane: B-219
  Branch: autopilot-lane/B-219
  Base: be2129990578913aa7929e6d8d253a33eb3c76a8
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: f928cc679f5b52e32040ffeaca9368686ae4b682
  Tokens: 11.3M in (10.7M cache read), ≥74.8k out, 131 requests
  Dispatched: 2026-11-15T01:51:24Z
  Call: Pin tests in LeoKit (Mac + iOS); no UI or reducer change — P3
  Call: No app-side "hide errored while running" rule — P2, D-011, D-785
  Call: Third pin: working at same/older revision does not clear errored — P2, D-011
  Call: Leo agent still gets the Go test spec; leo PR #327 only partly covers it — AUTONOMY (messaging the leo agent)

Lane: B-367
  Branch: autopilot-lane/B-367
  Base: 532d83b57db58ced22489f9ebbb2d1d9cfef31d6
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T02:18:48Z
  Tokens: 3.9M in (3.76M cache read), ≥17.1k out, 44 requests

Lane: B-397
  Branch: autopilot-lane/B-397
  Base: 6b04e104d3b3b51065cb072a2b2660118c7c0ac2
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T02:25:25Z

Finished 1: B-219 landed ba49266d9 · not visually verified
Finished 2: B-367 blocked

Progress:
- Picks: B-110 full (cross-window drag; hard implementer per D-784), B-219 full (errored attention; pin tests + leo agent per D-785). Independent footprints.
- Preflight: main merged (iOS Markdown viewer); queued bump PR #369 (leo 0.82.4) as B-399; inbox applied: B-397 bug, B-398 add, B-399 add; answered B-110, B-143, B-219, B-367 (leo PR #327 already merged), B-393 (fix ships in leo 0.82.4 → depends on B-399).
- Runners: B-110 d-886703974903, B-219 d-c80c5b6db7f4 (leo implement role), parallel.
- B-219 landed ba49266d9 (3ed071fec f928cc679): three LeoKit pin tests; Go test spec for the residual daemon gap sent to the leo agent by the orchestrator (the dispatch had no leo_send_message). Decisions D-789..D-792.
- Pick: B-367 light (chat reply end-to-end check). Built before B-143 (B-143 touches TerminalController, which may overlap open lane B-110).
- B-367 blocked: end-to-end check on an isolated leo 0.82.2 with autopilot-scratch: chat replies arrive before and after a simulated /clear; no app change. Waiting on owner close.
- Pick: B-397 light (Settings menu). Built before B-143 (TerminalController overlap with B-110) and B-393 (needs B-399).
