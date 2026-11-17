Status: running
Started: 2026-11-17T00:10:08Z
Budget: 20 items, until 2026-11-17T12:10:08Z
Digested-through: 0
Filed: 0/3 bugs, 5/5 ideas
Self-filed: B-413 → B-414 idea — Sidebar needs-you pill overlaps the edge row's text
Self-filed: B-413 → B-415 idea — Retake B-413 indicator shots with scratch-only rows
Self-filed: B-404 → B-416 idea — Download failure strip wraps to two lines
Self-filed: B-404 → B-417 idea — Download ending while the browser pane is closed shows nothing
Self-filed: B-404 → B-418 idea — Browser pane stays blank after a navigation becomes a download
Self-filed: B-407 → dropped (over cap) — Edit ▸ Find items show no ⌘F/⌘G/⌘⇧G key equivalents
Self-filed: B-407 → dropped (over cap) — Find match inside an overflow:auto box doesn't scroll into view
Self-filed: B-407 → dropped (over cap) — Hide Find Bar stays enabled with no bar up
Self-filed: B-407 → dropped (over cap) — Browser address bar shows the previous URL, one navigation behind
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
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 0b5e9bc034ad07b8aa371a78b7bb3ea09f527ee4
  Tokens: 67.8M in (66.6M cache read), ≥272k out, 411 requests
  Call: Saved name is the suggested name with `/`, `\` and control characters turned into `_`, leading dots stripped, capped at 200 bytes with the extension kept, `download` as fallback — P3
  Call: Name clash gets "name 2.ext", "name 3.ext", up to 100, then a plain failure; never overwrites — P2
  Call: Fetch to a private local temp folder, then publish atomically into `<workspace>/downloads/` through the file backend; a failure or lost connection leaves nothing behind — P3
  Call: `browser_downloads` is a new read-only tool listing kept downloads (absolute path and `workspace_path`, newest first, 50 ended entries kept); works while the user drives — D-759/D-762/D-764
  Call: A navigation that becomes a download returns navigate's normal ok — D-759
  Call: Pane strip: "Saved “x” to downloads/" hides after 5 s; failures say "Nothing was saved." and stay until dismissed; one VoiceOver announcement per outcome; close button at the trailing edge — P2
  Call: Closing a tab cancels its downloads; triggers are attachment responses, types WebKit can't show, `<a download>` to non-file URLs, and attachments inside frames — P4
  Call: Download tests use a loopback HTTP server, because WebKit custom-scheme handlers never produce downloads — test infrastructure
  Call: `removeStaging` added to the `LeoFileAccess` protocol, and `numbered` moved into LeoKit `LeoFileName` — implementation approach
  Call: Logic and tool in LeoKit (both platforms); WKDownload glue and strip Mac only; iOS comes with B-305 — parity rule

Lane: B-407
  Branch: autopilot-lane/B-407
  Dispatched: 2026-11-17T01:47:05Z
  Base: f1d8748307b0d94bbe67e579c7cc99f257c28564
  Tier: full
  State: landed
  Fixes: 2
  Wip: none
  Reverifies: 0
  Reviewed-tip: 9a4c38661cc8379e9aad202ee2e825245c740381
  Tokens: 87M in (85.7M cache read), ≥293k out, 557 requests
  Call: Safari-style find bar above the page, count "2 of 12" / "No matches" / "1000+" — P1
  Call: ⌘F/⌘G/⌘⇧G claimed whenever focus is anywhere in the browser pane (page, URL field, find field); terminal and editor paths untouched — P1
  Call: Finding is reading: no user-input event, no agent takeover — P2
  Call: Esc in the find field closes the bar, clears highlights, returns focus to the page — P1
  Call: Bar stays open across tab switches and page loads and re-searches; ⌘G with no query opens the bar — P2
  Call: Case-insensitive, no options; Edit ▸ Find shows no key equivalents, same as terminal and editor — P1 / item Out
  Call: Query is kept after Esc (result and highlights cleared); reopening searches it again — P2
  Call: Reveal scrolls the page only, not inner overflow:auto containers — scope (accepted gap)
  Call: Whitespace and nbsp collapse to one space, <br> counts as a break — P1

Lane: B-405
  Branch: autopilot-lane/B-405
  Dispatched: 2026-11-17T02:22:28Z
  Base: 2d3139ab68c7d824a6895f3854211d823fec400f
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-413 landed dd5910e72 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-413-1.png

Finished 2: B-404 landed 88a18c9fb · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-404-2.png

Finished 3: B-407 landed 290801942 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-407-17.png

Progress:
- Preflight: no open bump/leo-* PR. Merged main. Inbox applied: B-413 (sidebar off-screen attention). Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Pick: B-413 full (new sidebar feature, owner-added); B-404 full (new feature, file backend) in parallel — independent footprints (sidebar vs browser pane).
- Dispatched runners via leo_dispatch implement: B-413 d-79b7d16f0ad7, B-404 d-a8528e767eac.
- B-413 ready (fix 1). INCIDENT: first verify's GUI click on the pill attached Evan's real `assistant` agent (resized its tmux to 66x28 while attached); verifier detached+quit. Root cause fixed (pill exempt from row click monitor). Flag in digest.
- B-413 landed dd5910e72. D-822..D-831.
- Pick: B-407 full (find bar feature). B-407 built before B-405, B-406 (independent; those share B-404's workspace file-backend footprint).
- Dispatched B-407 d-97db0ebeb9a4.
- B-404 ready (fix 1, hard implementer, security review clean).
- B-404 landed 88a18c9fb. D-832..D-841.
- Pick: B-405 full (uploads; new tool + picker).
- Dispatched B-405 d-2c841ad94d65.
- B-407 ready (fix 2). Integrate conflict with B-404 strip resolved. Verifier incident: a mis-focused Return started `autopilot-scratch` (scratch only; stopped again). Edit ▸ Find key-glyph gap accepted as polish (items and shortcuts both work).
- B-407 landed 290801942. D-842..D-850.
