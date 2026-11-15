Status: running
Started: 2026-11-15T01:48:53Z
Budget: 20 items, until 2026-11-15T13:48:53Z
Digested-through: 5
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-397 → B-400 idea — Gear icon belongs on Settings…, not Open Ghostty Config
Self-filed: B-399 → dropped (dup of B-303) — Incremental macOS builds can skip the "Leo tmux terminfo" phase
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
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 808a4e7a88f89d32dc84ab661309709331aab306
  Dispatched: 2026-11-15T02:25:25Z
  Call: "Open Ghostty Config" has no shortcut (Ghostty's default open_config is also ⌘,) — P1
  Call: ⌘, in a terminal dispatches to Settings… by physical key, like ⌃Tab (B-059) — P1
  Call: Mac only; iOS has no app menu — P1
  Tokens: 9.46M in (9.14M cache read), ≥40.3k out, 100 requests

Lane: B-399
  Branch: autopilot-lane/B-399
  Base: 5cebbc8c0609e517c36ccbcb2a00f0b65f0e6407
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: c6519dfa74ccf189cb57d2bb2214f16b55c3a268
  Dispatched: 2026-11-15T03:07:22Z
  Tokens: 5.21M in (4.96M cache read), ≥20.8k out, 64 requests

Lane: B-393
  Branch: autopilot-lane/B-393
  Base: 199cdae170d70dead6a3cb7a355742227c8796bb
  Tier: full
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T03:43:45Z
  Call: No app change; the sidebar mirrors attention.state, the daemon reports working — P2
  Call: Mac/iOS both: no change; shared LeoKit decode — P3
  Call: Never-red LeoKit candidate test kept as evidence, not committed — Engineering Discipline
  Tokens: 9.48M in (9.07M cache read), ≥65.9k out, 98 requests

Finished 1: B-219 landed ba49266d9 · not visually verified
Finished 2: B-367 blocked
Finished 3: B-397 landed dde14dd4c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-397-1.png
Finished 4: B-399 landed 56857fc1f · not visually verified
Finished 5: B-393 blocked

Progress:
- Picks: B-110 full (cross-window drag; hard implementer per D-784), B-219 full (errored attention; pin tests + leo agent per D-785). Independent footprints.
- Preflight: main merged (iOS Markdown viewer); queued bump PR #369 (leo 0.82.4) as B-399; inbox applied: B-397 bug, B-398 add, B-399 add; answered B-110, B-143, B-219, B-367 (leo PR #327 already merged), B-393 (fix ships in leo 0.82.4 → depends on B-399).
- Runners: B-110 d-886703974903, B-219 d-c80c5b6db7f4 (leo implement role), parallel.
- B-219 landed ba49266d9 (3ed071fec f928cc679): three LeoKit pin tests; Go test spec for the residual daemon gap sent to the leo agent by the orchestrator (the dispatch had no leo_send_message). Decisions D-789..D-792.
- Pick: B-367 light (chat reply end-to-end check). Built before B-143 (B-143 touches TerminalController, which may overlap open lane B-110).
- B-367 blocked: end-to-end check on an isolated leo 0.82.2 with autopilot-scratch: chat replies arrive before and after a simulated /clear; no app change. Waiting on owner close.
- Pick: B-397 light (Settings menu). Built before B-143 (TerminalController overlap with B-110) and B-393 (needs B-399).
- B-397 landed dde14dd4c (36cc25719): Settings… opens Leo settings; Open Ghostty Config split out. D-793..D-795. Polish filed B-400 idea.
- Pick: B-399 light (leo 0.82.4 bump, PR #369). Built before B-143 (overlaps B-110) and B-393 (depends on this).
- B-399 landed 56857fc1f (39bcb2fb8, PR #369 head unchanged): bundled leo 0.82.4. Note: shared xcframework is stale (lacks ghostty_config_key_is_binding_for_action after 3d2b0d723); lanes build their own until shared/ is rebuilt.
- Pick: B-393 full (has shelved branch); end-to-end check of the pending.tasks hold on bundled leo 0.82.4. B-143 still waits on B-110 (TerminalController overlap).
- B-393 blocked (shelved autopilot-shelved/B-393-2): leo 0.82.3 red, 0.82.4 green on isolated daemon (hold keeps working with outstanding.tasks; turn.start clears); app mirrors it, no change. Waiting on owner close.
