Status: finished
Started: 2026-11-15T23:49:27Z
Budget: 20 items, until 2026-11-16T11:49:27Z
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

Lane: B-401
  Branch: autopilot-lane/B-401
  Base: 1a808ab8a6a4c79eaa1b33c61c01618e117c3c50
  Tier: full
  Tokens: 16.4M in (16M cache read), ≥62.6k out, 152 requests
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7bb9437bd9eece6e1b6df206f4fab2a03b32f8dd
  Dispatched: 2026-11-15T23:50:54Z
  Call: No client-side cache of `finished`; the agent JSON has no per-instance id that survives a restart — P2, D-790
  Call: Restore only at-rest states; `working` comes back as `unknown` — P2
  Call: Persisted records keyed by name + attention token — P2
  Call: Platform: both Mac and iOS, no app code, because the fix lives in the daemon — P3, D-789
  Call: Extra Mac pin `daemonRestartBaselineWithUnknownClearsTheRow`, the Mac twin of the LeoKit P2 pin — P2

Finished 1: B-401 landed 31d028fbd · not visually verified

Progress:
- Preflight: main already merged; no open bump/leo-* PR to queue; inbox applied: B-401 answered (accept pick: send leo agent the restore contract, pin tests here). Lanes B-233, B-332 unlanded with no RUN.md block (left in place); B-368 landed lane awaits finish.
- Pick: B-401 full (shelved branch + existing plan). Owner accepted pick: send leo the restore contract, add pins here.
- Runner: B-401 d-1493977acb3f (leo implement role).
- B-401 ready (general full review; no UI change, not visually verified). Runner couldn't reach leo_send_message, so the orchestrator sent the leo agent the contract + Go test spec at 2026-11-15 19:23 EST (AUTONOMY: messaging the leo agent). The lane doc's Send record still reads "not sent yet".
- B-401 landed 31d028fbd (339eb6d48 bf329b86f 039a03178 50805c6ce). D-816..D-820. ≈$4.59 est.
- Digest: backlog drained (pick []). lane finish skipped B-368 (dirty worktree, 1 change).
