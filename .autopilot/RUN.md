Status: running
Started: 2026-11-27T20:46:59Z
Budget: 20 items, until 2026-11-28T08:46:59Z
Digested-through: 0
Filed: 0/3 bugs, 2/5 ideas
Self-filed: B-465 → B-467 idea — iOS dismissTarget duplicates LeoKit's dismiss rule
Self-filed: B-465 → B-468 idea — Mac ⌫ on last blocked row selects the unread finished row
Untracked-left: default.profraw scratchpad/
Note: no open bump/leo-* PR at preflight.

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-461
  Branch: autopilot-lane/B-461
  Base: b49c7540a536b323c03cdb8f344eab010d97b64f
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-27T20:51:40Z

Lane: B-465
  Branch: autopilot-lane/B-465
  Base: b2dbe33218b2d90bc9d3381b9fb1d669d9f3dc11
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 085330cbca6a88bba8c9fa50920acdabc20ec63f
  Dispatched: 2026-11-27T21:47:14Z
  Tokens: 60.5M in (59.1M cache read), ≥281k out, 401 requests
  Call: Dismissal reuses the synced seen mark (`seen_at` >= `dismissAt`), no daemon change — VISION 3, Mac+iOS rule
  Call: Opening or viewing never marks a blocked agent seen, and the gate fails closed while data is still loading — VISION 2
  Call: A partial seed does not count as "loaded"; `LeoOpenAsks.markLoaded(host:)` is called on the old-daemon "no route" result — VISION 2
  Call: A dismissed item leaves the list, badge and "Needs you" count, while the sidebar and Dock still show the daemon's needs-input state — VISION 2
  Call: Stopped agents contribute nothing to the inbox, finished ones included, in one LeoKit rule — VISION 2
  Call: Mac: ⌫ dismisses a blocked row; Agents ▸ "Dismiss from Inbox" has no plain-key equivalent, so Delete is never taken from text fields — VISION 1
  Call: iOS: full swipe plus a visible Dismiss button plus a context-menu item — Mac+iOS rule
  Call: Local mode stores the ask time (`Mark.at`), so a new ask in the same turn resurfaces on older daemons — acceptance criterion
  Call: iOS launch chip counts `inbox.blocked`, so an all-dismissed launch lands on All — VISION 2

Finished 1: B-465 blocked
Finished 2: B-465 landed 77cca5f72 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-465-1.png
Note: B-465 runner shots (implementer's, unverified) left at /private/tmp/claude-501/b465/macgui/shots/ and /private/tmp/claude-501/b465/shots-ios/.
Inbox applied: B-466 idea; answered B-465 (accept your recommendation: ship plain Dismiss, cancel-ask split to B-466)
