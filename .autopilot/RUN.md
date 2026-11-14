Status: running
Started: 2026-11-14T19:26:16Z
Budget: 20 items, until 2026-11-15T07:26:16Z
Digested-through: 0
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-395 → B-396 idea — iOS move progress shows the daemon's move stages
Self-filed: B-395 → dropped (dup of B-370) — verify.md -ApplePersistenceIgnoreState shows a Configuration Errors dialog
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

Lane: B-393
  Branch: autopilot-lane/B-393
  Base: 68bd2d14e7fd95bbed8998005bf9718f91e8f383
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-14T19:29:03Z
  Tokens: 1.46M in (1.34M cache read), ≥7.42k out, 19 requests
  Call: no app change; the app already mirrors the daemon attention state — VISION 2

Lane: B-395
  Branch: autopilot-lane/B-395
  Base: 68bd2d14e7fd95bbed8998005bf9718f91e8f383
  Tier: light
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1ac9b0f24923f0538b9fa7a2b34424e5799b5fde
  Dispatched: 2026-11-14T19:29:03Z
  Call: Mac only for now; iOS refusal already shows an alert, iOS stage display deferred (filed B-396) — repo Mac/iOS rule
  Call: Stage names shown raw, as the daemon reports them — VISION 2 (calm, don't invent phases)
  Call: No completion banner; the row turns "moved" after refresh — VISION 2
  Call: No progress sheet; the row detail line shows the stage — avoids a new surface needing a design call
  Call: Refusal shown as an NSAlert plus a row-error trace — VISION 1

Finished 1: B-393 blocked

Progress:
- Preflight: main merged; no open bump/leo-* PR; inbox applied: created B-393, B-395 (bugs), B-394 (idea); B-014/B-380 dropped per owner answers; B-051 dropped (owner, in session). Inbox entry 20261114T012321201831Z-fc7a345a (CI flakes, "/issue leoterm: …" prefix) unparseable, not applied.
- Picks: B-393 light (sidebar attention state), B-395 light (move UI feedback). Independent footprints.
- Runners: B-393 d-dc298b94317b, B-395 d-9b747e361293 (leo implement role), parallel.
- B-393 blocked: root cause daemon-side (bridgefeed.go turnCompleteLocked ignores ev.Pending for supervised agents); no app change. Did not message the leo agent: owner declined that action earlier this session and dropped B-051.
