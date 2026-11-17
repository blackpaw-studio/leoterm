Status: running
Started: 2026-11-17T00:10:08Z
Budget: 20 items, until 2026-11-17T12:10:08Z
Digested-through: 0
Filed: 0/3 bugs, 2/5 ideas
Self-filed: B-413 → B-414 idea — Sidebar needs-you pill overlaps the edge row's text
Self-filed: B-413 → B-415 idea — Retake B-413 indicator shots with scratch-only rows
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

Lane: B-413
  Branch: autopilot-lane/B-413
  Dispatched: 2026-11-17T00:13:40Z
  Base: 1a9361eecbb9960c562f109facd6bdebbe74108e
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 21ec5304b98c4da25ede4fd76fa997826681a969
  Tokens: 44M in (43M cache read), ≥184k out, 292 requests
  Call: Needs you = displayed Needs You or Error state (including a failed-action error), or an unread badge; working, finished, idle and stopped rows count only with unread — P2
  Call: Collapsed groups, folded or offline machines, filtered-out rows and dispatch rows never count — Out (collapsed sections), P2
  Call: A row is in view when its midY is inside the unobscured area — AUTONOMY UX detail
  Call: Capsule at the top or bottom edge, material with a hairline, arrow plus "Needs you" or "N need you", tinted by state (orange needs you, red error, accent unread) — P1, P2
  Call: No fade: the capsule appears and disappears instantly (plan said fade; instant is calmer and keeps hosted tests deterministic) — P2
  Call: A click scrolls instantly, centering the nearest row; it never selects, attaches or takes focus — P6, P2
  Call: The capsule is an AppKit view acting as the single accessibility button; it takes focus only from keyboard navigation with Full Keyboard Access on — P1
  Call: VoiceOver label "Scroll up/down to <name>, <state>"; no new shortcut — P1
  Call: Mac only; iOS has the needs-you inbox — parity rule, Out
  Call: DEBUG-only `unread` fixture key: unnamed local agents read 0 when it's present; an explicit 0 is honored — verification tooling

Lane: B-404
  Branch: autopilot-lane/B-404
  Dispatched: 2026-11-17T00:13:40Z
  Base: 1a9361eecbb9960c562f109facd6bdebbe74108e
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-413 landed dd5910e72 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-413-1.png

Progress:
- Preflight: no open bump/leo-* PR. Merged main. Inbox applied: B-413 (sidebar off-screen attention). Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Pick: B-413 full (new sidebar feature, owner-added); B-404 full (new feature, file backend) in parallel — independent footprints (sidebar vs browser pane).
- Dispatched runners via leo_dispatch implement: B-413 d-79b7d16f0ad7, B-404 d-a8528e767eac.
- B-413 ready (fix 1). INCIDENT: first verify's GUI click on the pill attached Evan's real `assistant` agent (resized its tmux to 66x28 while attached); verifier detached+quit. Root cause fixed (pill exempt from row click monitor). Flag in digest.
- B-413 landed dd5910e72. D-822..D-831.
