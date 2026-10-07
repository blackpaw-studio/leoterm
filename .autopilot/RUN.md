Status: running
Started: 2026-10-07T16:40:34Z
Budget: 20 items, until 2026-10-08T04:40:34Z
Digested-through: 5
Filed: 1/3 bugs, 5/5 ideas
Self-filed: B-257 → B-263 idea — Index dispatch children once per tree projection
Self-filed: B-257 → B-264 idea — Dispatch tombstone cap survives heavy churn
Self-filed: B-257 → B-265 idea — Tighten fetchCount bound in dispatchAndSeqOnlyEventsLeaveThePendingActivityWindowAlone
Self-filed: B-257 → B-266 idea — Clicking a dispatch row reveals or jumps to the dispatch
Self-filed: B-257 → B-267 idea — Clearer depth indent for dispatch rows
Self-filed: B-258 → B-268 bug — Same-state needs_input with a newer revision re-notifies
Self-filed: B-258 → dropped (over cap) — Bidi-isolate attention tool and detail text
Self-filed: B-259 → dropped (over cap) — Usage-only subtitle can overflow on a very narrow row
Self-filed: B-259 → dropped (over cap) — Thousands separator for cost
Self-filed: B-259 → dropped (over cap) — Drop cost before context % on narrow rows
Self-filed: B-260 → dropped (over cap) — Friendlier display for MCP tool names
Self-filed: B-261 → dropped (over cap) — Compaction started between spawn and post-spawn /state never shows
Self-filed: B-261 → dropped (over cap) — Turn completion mid-compaction clears the indicator early
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
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 4a2300cac698ccff17b2cf2fe67292a11ffc11cd
  Dispatched: 2026-10-07T20:36:39Z
  Call: The preview replaces the task line and shows only when there is no current task. It is not hidden while the agent is working — P2 calm, P6
  Call: Usage is the session's tokens, cost and context %, shown as a subtitle segment that drops whole components when space runs out, never part of a number. The full session and since-start numbers go in the tooltip and VoiceOver. There is no inspector because none exists — P2, AUTONOMY UX
  Call: An aborted turn reads "Interrupted: <preview>". An empty preview clears the line, and usage that is all zero shows nothing — P2 never invent
  Call: Cost below half a cent reads "<$0.01" — AUTONOMY UX
  Call: Preview and usage are gated on the hello's `bridge_turns`/`agent_usage` features. Nothing renders while disconnected — P2, D-377
  Call: Turn and usage events only trigger a /state refresh. The preview text is the only value taken from an event — D-082
  Call: No badge, motion or notification on turn completion — P2
  Call: Preview is clamped to 200 chars (reuses LeoSFTPServerText) and bidi-isolated at display — AUTONOMY implementation
  Call: The DEBUG fixture's `usage`/`turns` keys advertise the features and replay the turns after each hello — D-018, AUTONOMY test infra

Lane: B-260
  Branch: autopilot-lane/B-260
  Base: c45f2efbddc07721068059590875af0d9e3e3038
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: aed36d0e44d55bcac463277c2bd05722830372a3
  Dispatched: 2026-10-07T20:49:14Z
  Call: Show only the tool name (first token of sanitized detail), never summary/arguments — item Out + principle 2
  Call: Tool line = static secondary-grey hammer + name in the task line's place, hides the B-259 turn preview while a tool runs; no badge/motion — principle 2, AUTONOMY UX details
  Call: No feature gating: kind "tool" names itself; pane/nil/unknown kinds keep today's full-detail task line — principle 2 (never invent state)
  Call: Tool name with a space shows only its first word (detail never shown for "tool") — principle 2
  Call: CSI/OSC escape stripping scoped to toolName(fromDetail:); task-line sanitizer unchanged — principle 2
  Call: "Running X" tooltip/VoiceOver label bidi-isolated like B-259's turn line — principle 1
  Call: DEBUG fixture key "actions" (agent → {kind, detail}) overrides current_action for verification — AUTONOMY test infra

Lane: B-261
  Branch: autopilot-lane/B-261
  Base: b44801a88984d027cdebafa69657665642d0922d
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 764ca502eb326d00089a9961d98dd12c4308ebb8
  Dispatched: 2026-10-07T21:52:25Z
  Call: No hello feature gate for compaction; the event's existence is the proof (as D-399); hidden while disconnected (D-392) — principle 2
  Call: Compaction phase is event-sourced because /state has none; context % stays /state-only, refreshed on the end event (D-082/D-393); the event's context_percent is decoded but never shown (pre-compaction value) — principle 2
  Call: Static grey arrow.down.right.and.arrow.up.left + "Compacting context" in the task-line slot above tool/task/preview; trigger only in the tooltip ("(automatic)"/"(requested)"); no badge/motion/notification — principle 2, AUTONOMY UX details
  Call: `failed` clears quietly — principle 2
  Call: Clears on gap/reconnect/disconnect/host switch/boot change/stop/spawn/turn completion, never a timer — principles 2, 5
  Call: DEBUG fixture key "compactions" (agent → [{phase, trigger}], replayed after hello 1.5 s apart) — AUTONOMY test infra (D-018/D-403)
  Call: TurnHarness test helpers made non-private (+ setUsage) for reuse — AUTONOMY test infra

Lane: B-262
  Branch: autopilot-lane/B-262
  Base: 25896e3f350ee6aeb20d9aa65e9f165661958933
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

## Progress
Finished 1: B-257 landed 8a28dfb7bd072c049000f75f71a3fd3c976b8a83 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-257-2.png
- B-257 landed 8a28dfb7b: nested dispatch rows under the parent via parent_dispatch_id, gated on hello dispatch_tree; SSE-trace replay test; 1 fix round (baseline ordering); suite 2126 green. Polish filed (5).
Finished 2: B-258 landed 1af002341338cf3e434cc9cc68aed00599127b89 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-258-3.png
- B-258 landed 1af002341: attention reason as per-kind badge symbol, tooltip, subtitle word, VoiceOver label and notification text; suite 2142 green; 0 fix rounds. Self-filed bug B-268 (re-notify on revision bump).
- Session interrupted at ~20:25Z; lock taken over by the new session (pid 79355); B-259 runner resumed from its transcript (lane clean at 9ac97cddb, mid fix round).
Finished 3: B-259 landed ed7558b973dafbadc1db205fb0085d0e8ea12ffa · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-259-1.png
- B-259 landed ed7558b97: last-turn preview line and usage subtitle segment (tokens/cost/context %), gated on hello bridge_turns/agent_usage; verified live against leo 0.37.0; 1 fix round. 3 polish dropped (idea cap).
Finished 4: B-260 landed 928f15569c87bc05240f32796cc00e7fa7ee31a8 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-260-1.png
- B-260 landed 928f15569: running tool shown as grey hammer + tool name in the task line while current_action kind is tool; clears when the call ends; suite 2183 green; 1 fix round.
Finished 5: B-261 landed bf8e5b9f40a6fec1162a3db210f4d8c06cfcecdf · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-261-1.png
- B-261 landed bf8e5b9f4: 'Compacting context' line from agent_compaction events, cleared on end/failed/gap/stop; context % refreshed from /state; suite 2207 green; 0 fix rounds. Note: lane history carries a 2.2 MB macos/default.profraw blob (added 65f17bdd6, untracked 764ca502e); not rewritten (Never list).
