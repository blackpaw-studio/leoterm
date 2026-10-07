Status: running
Started: 2026-10-07T16:40:34Z
Budget: 20 items, until 2026-10-08T04:40:34Z
Digested-through: 0
Filed: 1/3 bugs, 5/5 ideas
Self-filed: B-257 → B-263 idea — Index dispatch children once per tree projection
Self-filed: B-257 → B-264 idea — Dispatch tombstone cap survives heavy churn
Self-filed: B-257 → B-265 idea — Tighten fetchCount bound in dispatchAndSeqOnlyEventsLeaveThePendingActivityWindowAlone
Self-filed: B-257 → B-266 idea — Clicking a dispatch row reveals or jumps to the dispatch
Self-filed: B-257 → B-267 idea — Clearer depth indent for dispatch rows
Self-filed: B-258 → B-268 bug — Same-state needs_input with a newer revision re-notifies
Self-filed: B-258 → dropped (over cap) — Bidi-isolate attention tool and detail text
Focus: leo PR #226 bridge features (B-257–B-262, then B-051)
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

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
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-257
  Branch: autopilot-lane/B-257
  Base: 77e6c369d45f811c845c452353e322f0b82df0a1
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: f3371acc7fa8456db63f9ae389c063b41127380c
  Dispatched: 2026-10-07T16:43:28Z
  Call: Children disappear as soon as the daemon reports a terminal status or ended_at, with no 60 s linger — principle 2
  Call: A child row shows name (falling back to role, then "Dispatch") plus a status word; Stalled is plain secondary text with no badge — principle 2
  Call: Child rows can't be selected (no tag, plus selectionDisabled on macOS 14+), and there are no new shortcuts — principles 1 and 6
  Call: Nothing renders without the hello `dispatch_tree` feature or while disconnected; the parent badge stays purely the daemon's attention.state, and `outstanding` isn't decoded — principle 2
  Call: Disconnect clears records but keeps same-boot ended ids, a boot change clears all, a host switch resets, and a Retry baseline repairs anything missed — principle 5
  Call: Caps that only bound a misbehaving daemon: 256 ended ids, 1024 live records, nesting depth 16, indent clamped at depth 4; only nesting changes emit — principle 2

Lane: B-258
  Branch: autopilot-lane/B-258
  Base: 2877d486c4ba732de773a91b2ddbaed3ad6be4a7
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 5ea1d7a4ae06bdb0ab115a8996e362cc3a7a5f9b
  Dispatched: 2026-10-07T19:07:44Z
  Call: Badge stays icon-only (D-012); the reason shows as a per-kind symbol (hand.raised / questionmark.bubble / list.bullet.rectangle), a badge tooltip, the subtitle word ("Permission: Bash" / "Question" / "Input Request") and the VoiceOver label — principles 1, 2
  Call: Detail appears only in the badge tooltip; notifications carry kind and tool only — principle 2, D-013
  Call: No hello `attention_reason` gate; an absent field means no reason — principle 2
  Call: An unknown or malformed reason kind reads as no reason (falls back to today's behaviour) — principle 2
  Call: A reason refining an already-committed reasonless needs_input updates the badge without re-notifying (check lives in reducer commit()) — principle 2
  Call: A reason on a row whose badge isn't needsInput is ignored — principle 2
  Call: Tool and detail are sanitized and clamped in LeoAttentionReason.init, so every construction path is clean — principle 2
  Call: Labels, symbols and wording per the plan; Badge.tooltip is optional (default nil); `.help("")` when there is no reason — AUTONOMY copy/UX

Lane: B-259
  Branch: autopilot-lane/B-259
  Base: 581402230961f47a750152bd3e62b7421b6eec52
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-07T19:39:39Z

## Progress
Finished 1: B-257 landed 8a28dfb7bd072c049000f75f71a3fd3c976b8a83 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-257-2.png
- B-257 landed 8a28dfb7b: nested dispatch rows under the parent via parent_dispatch_id, gated on hello dispatch_tree; SSE-trace replay test; 1 fix round (baseline ordering); suite 2126 green. Polish filed (5).
Finished 2: B-258 landed 1af002341338cf3e434cc9cc68aed00599127b89 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-258-3.png
- B-258 landed 1af002341: attention reason as per-kind badge symbol, tooltip, subtitle word, VoiceOver label and notification text; suite 2142 green; 0 fix rounds. Self-filed bug B-268 (re-notify on revision bump).
