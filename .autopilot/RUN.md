Status: running
Started: 2026-11-17T00:10:08Z
Budget: 20 items, until 2026-11-17T12:10:08Z
Digested-through: 5
Filed: 3/3 bugs, 5/5 ideas
Self-filed: B-413 → B-414 idea — Sidebar needs-you pill overlaps the edge row's text
Self-filed: B-413 → B-415 idea — Retake B-413 indicator shots with scratch-only rows
Self-filed: B-404 → B-416 idea — Download failure strip wraps to two lines
Self-filed: B-404 → B-417 idea — Download ending while the browser pane is closed shows nothing
Self-filed: B-404 → B-418 idea — Browser pane stays blank after a navigation becomes a download
Self-filed: B-407 → dropped (over cap) — Edit ▸ Find items show no ⌘F/⌘G/⌘⇧G key equivalents
Self-filed: B-407 → dropped (over cap) — Find match inside an overflow:auto box doesn't scroll into view
Self-filed: B-407 → dropped (over cap) — Hide Find Bar stays enabled with no bar up
Self-filed: B-407 → dropped (over cap) — Browser address bar shows the previous URL, one navigation behind
Self-filed: B-405 → dropped (over cap) — Upload picker header says "a file" for a multiple input
Self-filed: B-405 → dropped (over cap) — Agent browser_click on a file input still opens the picker
Self-filed: B-408 → B-419 bug — Browser address field shows a stale URL while focused
Self-filed: B-408 → B-420 bug — ⌘L doesn't select the browser address field's text
Self-filed: B-408 → B-421 bug — Open browser pane collapses ~15 s after autopilot-scratch stops
Self-filed: B-408 → dropped (over cap) — History button opens its menu on any drag instead of going back
Self-filed: B-408 → dropped (over cap) — Browser host re-focuses the web view on every refresh
Self-filed: B-406 → dropped (over cap) — Full-page PNG has a ~17 px white strip on the right edge
Self-filed: B-406 → dropped (over cap) — Workspace browser truncates file names in the middle
Self-filed: B-406 → dropped (over cap) — Save menu items disabled with no hint outside the browser pane
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
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: fe8616f1124456209561d53a44b9a247956292d7
  Tokens: 83.3M in (82M cache read), ≥299k out, 499 requests
  Call: browser_upload is a new tool and fails with user_has_control while the user drives — D-732/D-734/D-764
  Call: Upload paths are workspace-relative or absolute inside the workspace; outside is invalid_args — P3, P4
  Call: Upload limits 20 files / 25 MB / 120 s; missing path is no_such_file; folder is invalid_args — P2
  Call: browser_upload result shape {name,size,workspace_path} with no absolute path, matching browser_downloads — D-835
  Call: Snapshot marks file inputs [file] [multiple] [accept] [disabled] [hidden], including hidden inputs — Done #3
  Call: Picker is a standalone "Choose from Workspace" panel rooted at the workspace; "Choose from Mac…" is secondary; folder inputs and agents with no workspace go straight to Finder — P1, P2
  Call: Chosen files are copied to a per-app temp folder, removed on browser close and swept at launch, the same for local and SFTP — P3, D-834
  Call: Added a file_error code for permission errors and lost connections; an agent with no workspace gets no_such_file with a clear message — P2
  Call: Upload tool and reader in LeoKit; picker Mac only, iOS picker with B-305 — D-841

Lane: B-406
  Branch: autopilot-lane/B-406
  Dispatched: 2026-11-17T05:11:29Z
  Base: 641b72e22435a6fb0945fba72d1b5a100bdd2c29
  Tier: full
  State: landed
  Fixes: 2
  Wip: none
  Reverifies: 0
  Reviewed-tip: 085ab9748c79c85a67d19b0d79c5235025a19227
  Tokens: 89M in (87.6M cache read), ≥323k out, 541 requests
  Call: New `browser_pdf` tool, plus `path` on `browser_screenshot` (`full_page` already existed) — item, D-759
  Call: Saved PDF is one continuous page of the whole document, not paginated for printing (WebKit splits past 14,400 pt) — P1, item Out
  Call: Default capture target `downloads/<title>.pdf|.png`, falling back to host name, then `page` — D-832, D-834, P3
  Call: A capture name clash gets a numbered name and the real name is reported; nothing is overwritten — D-833, P2
  Call: Capture path rules: workspace-relative or absolute inside the workspace; trailing `/` means default name; missing folders created; missing extension appended; wrong extension, `..` or outside path is `invalid_args` — P3
  Call: A screenshot with `path` returns the saved path, not the image — P2
  Call: Captures are reads: they work while the user drives — D-844, D-835
  Call: Save Page as PDF… ⇧⌘S, Save Full-Page Screenshot… ⌥⇧⌘S; enabled only with focus in the browser pane and a page loaded — P1, D-843
  Call: Save uses a one-field workspace path sheet, because NSSavePanel can't browse SFTP — P3
  Call: Saved strip shown for menu saves only, with D-837 copy — P2
  Call: Capture tool and logic in LeoKit (both platforms); menu/sheet/WebKit Mac only, iOS with B-305 — D-841
  Call: Capture path details: empty path is invalid_args; a real extension is 1–8 ASCII letters/digits; default name never doubles an extension; `/ws/` saves the default name at the workspace root, `/ws` is rejected; save errors become `save_failed`; menu items disabled on about:blank and while the sheet is up — implementer
  Call: Full-page PNG is rendered from createPDF over a rect capped at viewport width × min(scrollHeight, 16,384 pt), replacing takeSnapshot (blank below the viewport) — bug fix

Lane: B-408
  Branch: autopilot-lane/B-408
  Dispatched: 2026-11-17T05:51:09Z
  Base: fbc0a72cdb1584e393c07052d8148754f06e441f
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 15fe279c54c5bf8bf4d73987f804fcd3ed9036d9
  Tokens: 28.8M in (28M cache read), ≥164k out, 237 requests
  Call: ⌘[ / ⌘] / ⌘⇧T claimed only while focus is in the browser pane; Ghostty undo/goto_split untouched elsewhere — P1, follows D-843
  Call: History menu (Back, Forward, Reopen Closed Tab) between View and Agents, no key equivalents — P1, D-847
  Call: Every close is reopenable (user ×, agent tool, window.close()); blank tabs skipped; cap 20 per agent; stack dies with the browser — P2
  Call: Reopened tab returns at its old index with its UA override; back history not restored — P1
  Call: Reopen and history jumps count as user input and take control; impossible actions beep — P2
  Call: Press-and-hold 0.4 s, history menus show 20 entries, titles cut at 60 chars, VoiceOver show-menu — P1
  Call: Focus moves to the replacement page when the focused page leaves the slot — P1
  Call: A reopen whose URL-mapping load fails is logged and the entry is lost — P2, accepted
  Call: A stale focus claim can linger if a slot isn't the winning viewer when its page is released — accepted edge

Lane: B-409
  Branch: autopilot-lane/B-409
  Dispatched: 2026-11-17T06:56:17Z
  Base: 2089f6acfe74c47fdbe41e05543f641d2b3ee562
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-410
  Branch: autopilot-lane/B-410
  Dispatched: 2026-11-17T07:57:32Z
  Base: 4ff9c5089fa085f39fa048a9f6d8b266e244c627
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-413 landed dd5910e72 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-413-1.png

Finished 2: B-404 landed 88a18c9fb · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-404-2.png

Finished 3: B-407 landed 290801942 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-407-17.png

Finished 4: B-405 landed 9cf0c4069 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-405-1.png

Finished 5: B-408 landed 346db3e91 · screen capture, not attached

Finished 6: B-406 landed aecf8c1ca · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-406-4.png

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
- Pick: B-406 full (save page as PDF/screenshot; menu + tool).
- Dispatched B-406 d-7b7dd4233572.
- B-405 ready (fix 1, hard implementer, security review). Picker buttons not GUI-driven (Peekaboo clicks didn't register); SFTP covered by tests only.
- B-405 landed 9cf0c4069. D-851..D-859.
- Pick: B-408 full (reopen closed tab + history menus).
- Dispatched B-408 d-a01e72312213.
- B-408 ready (0 fixes, general review). Shots are screen captures only (not attached). Verifier denied Screen Recording prompts and force-killed the debug app.
- B-408 landed 346db3e91. D-860..D-868.
- Pick: B-409 full (menu actions + data store clearing).
- Dispatched B-409 d-d470908db7cd. Interim digest 1 posted (items 1–5).
- B-406 ready (fix 2, hard implementer, security review). Accepted: symlinked folder inside the workspace allows writes outside (lexical confinement; agent has a shell there).
- B-406 landed aecf8c1ca. D-869..D-881.
- Pick: B-410 full (permissions prompts; security-sensitive).
- Dispatched B-410 d-bc762c591f42.
