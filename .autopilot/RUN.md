Status: running
Started: 2026-11-17T14:04:05Z
Budget: 20 items, until 2026-11-18T02:04:05Z
Digested-through: 0
Filed: 3/3 bugs, 3/5 ideas
Self-filed: B-305 → B-422 bug — Hosted iOS test host crashes on unimplemented PushCleanupClient.load
Self-filed: B-305 → B-423 idea — iOS address bar keeps the previous URL after a rejected localhost navigation
Self-filed: B-305 → B-424 idea — Device check: keyboard raised when the agent focuses a field hides the iOS pill
Self-filed: B-305 → B-425 idea — Daemon localhost proxy so iPhone pages can reach an agent machine's localhost
Self-filed: B-419 → B-426 bug — After Return on a new address, the bar shows the old page's URL until the new page commits
Self-filed: B-419 → dropped (dup of B-420) — Typing after clicking the bar appends to the old URL (focus doesn't select all)
Self-filed: B-419 → B-427 bug — Takeover pill's "Give Back" click does nothing after a Return commit
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

Lane: B-305
  Branch: autopilot-lane/B-305
  Dispatched: 2026-11-17T14:07:51Z
  Base: 25f86d23516a1cde24a21643f1cda05e20ba8bb1
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Tokens: 108M in (106M cache read), ≥477k out, 581 requests
  Reviewed-tip: 777769817707c64aba9aa61772738740a36f8067
  Call: iOS is a second browser provider over HTTPS/SSE (daemon already accepts device tokens, no leo change); it claims unowned requests after a 1.5 s grace so a connected Mac wins, and claims requests it owns at once — P1, P2
  Call: Remote localhost gets no route, only a plain `localhost_unreachable` explanation in the tool error and the pane; Open in Safari is disabled for those URLs; a daemon proxy is a backlog follow-up — P3, P2
  Call: Upload, pdf, screenshot `path` and download saving return `unsupported` on iOS (no file backend); the tool list stays identical to the Mac's — scope-cut allowance, D-841/D-859/D-879
  Call: Agent input on iOS uses page JS events; only trusted taps/keys take control — P4, D-844/D-864
  Call: On background: in-flight calls answered `cancelled`, permission asks denied and withdrawn, dialogs stay pending, then the stream closes; resume re-registers and recovers — P2, D-894/D-913
  Call: System find bar and WebKit file picker replace D-842/D-856 on iOS; geolocation denied; camera/mic reuse the D-890–D-895 copy; Clear Site Data uses a destructive alert — P1/HIG
  Call: "Agent Browser on This iPhone" setting defaults on, mirroring the Mac; Mac copy reused for the pane
  Call: Platform call: both. Session, registry and loopback policy moved to LeoKit; the Mac only switched to the moved types

Lane: B-419
  Branch: autopilot-lane/B-419
  Dispatched: 2026-11-17T16:55:34Z
  Base: 25f86d23516a1cde24a21643f1cda05e20ba8bb1
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 1
  Tokens: 49.4M in (48.4M cache read), ≥142k out, 407 requests
  Reviewed-tip: 37575206bfe3530519058523f389726af7cb6752
  Call: Mac only: AppKit pane UI, iOS has no pane equivalent, so nothing goes in LeoKit — P1
  Call: Escape restores the page address and resumes following — P1 Safari parity
  Call: Leaving the bar with an unsent edit drops the edit and shows the page URL — P1
  Call: Return commit and a tab change hand the bar back to the page — P1

Lane: B-421
  Branch: autopilot-lane/B-421
  Dispatched: 2026-11-17T16:53:52Z
  Base: 97efeb2da678b49ec08b43db632f004a7fd399ee
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Finished 1: B-305 landed 961f5f8a7 · screen capture, not attached
Finished 2: B-419 landed 075ad32a2 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-419-1.png

Progress:
- Preflight: no open bump/leo-* PR. main already merged. Inbox empty. Promoted B-419, B-420, B-421. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Board sync: B-404: gh issue view: dial tcp 140.82.114.6:443: i/o timeout
- Pick: B-305 full (iOS executor, milestone 4; pick order lists it first); B-419 light bug (address field) in parallel — independent footprints (iOS app vs Mac browser pane). B-420 overlaps B-419 (address field); waits.
- Dispatched runners via leo_dispatch implement: B-305 d-faad684af5f4, B-419 d-fcc99dfe43e6.
- leo agent (10:03 EST): lost-dispatch bug (bridge-connect timeout under load → relaunch killed, turn marked lost) fixed in leo main PR #345 (945a27d3), unreleased. If a runner comes back lost/exit 137, re-dispatch rather than treat as a runner failure.
- B-305 ready (fix 1, hard implementer, concurrency review). Shots are screen captures only (simulator). Calls checked against D-822..D-916: iOS platform adaptations, no contradiction.
- B-305 landed 961f5f8a7. D-917..D-924. ≈$39.10 est.
- Pick: B-421 light bug (pane collapse on agent stop). B-421 built before B-420 (independent; B-420 overlaps B-419's address field).
- Dispatched B-421 d-117d1e98df4f.
- B-419 ready (fix 1, standard implementer, general review). Integration stale (B-305 landed Mac/LeoKit changes) → re-verify round 1. Runner note: shared GhosttyKit.xcframework is stale since B-334; lanes build their own.
- Dispatched B-419 re-verify d-4c616368bfee.
- B-419 re-verify ready (general delta clean, 5016 tests). Fresh.
- B-419 landed 075ad32a2. D-925..D-928. ≈$11.23 est.
