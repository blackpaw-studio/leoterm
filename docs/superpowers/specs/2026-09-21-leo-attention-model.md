# Leo attention model — approval draft (2026-09-21)

Status: DRAFT, awaiting Evan's approval. Drafted by codex-planner (gpt-6-astra).

**Scope.** Row badges, selected-host Dock count, background-agent notifications,
and "Jump to Next Needing Attention". Swift only, under `Features/Leo` plus
existing AppDelegate/menu hooks. Zero Zig changes.

## Signal contract and state machine

- Today `/events` emits `agent_activity(activity: working|idle|unknown,
  current_action)`; `/state` carries the same per agent. `working` = terminal
  output seen; `idle` = quiet. Neither means "finished" or "needs input".
- `agent_spawned`, `agent_state_changed(starting|running|stopped)`,
  `agent_stopped` are lifecycle only (stop covers dormancy, restart, delete,
  rename). `task_run_*` has no reliable agent identity. Never parse
  `current_action.detail`.
- **Leo-daemon prerequisite (separate team, via the leo agent):** optional
  `attention: {state, revision}` on `agent_activity`, `/state` agents and
  spawned-agent payloads. `state ∈ working|needs_input|finished|errored|unknown`;
  `revision` increases per agent per daemon lifetime. Absent = unsupported;
  explicit `unknown` clears. Producers: turn start/resume → working; unresolved
  question/approval → needs_input; turn completed → finished; terminal failure
  or unexpected exit → errored; explicit stop/cancel → unknown; delete removes.
- Authoritative attention replaces prior state at a newer revision and persists
  until the next semantic transition; idle samples and output never overwrite.
- Without semantic attention: legacy `working` may show Working; everything
  else shows the existing lifecycle badge only. Never invent a state.
- "Needing attention" = needs_input | finished | errored.

## Reducer, timing, recovery

- `LeoAttentionReducer` (value type, owned by `LeoSidebarFeed`, keyed by
  (host, agent)); inputs = decoded events, snapshots, host-generation changes,
  clock ticks; outputs = state, deadlines, committed transitions. No AppKit,
  network, or wall clock inside.
- Commit after 300 ms stability; same-state repeats do not extend, a different
  candidate replaces. Identical snapshots emit nothing.
- Ignore duplicate/older revisions. On hello/reconnect/sequence gap: cancel
  candidates, take a silent `/state` baseline, merge buffered events by
  revision. Baselines never notify.
- Host switch clears counts and pending effects; disconnect marks states stale
  and excludes them from count/navigation until resync. Keep selected-host SSE
  alive while sidebars are hidden or the app is in the background.

## Presentation and navigation

- Badges: Working `gearshape`/blue, Needs Input `questionmark.circle`/orange,
  Finished `checkmark.circle`/green, Errored `exclamationmark.triangle`/red.
  Static, caption text, no animation. VoiceOver row value "alpha, Needs Input";
  symbols hidden from accessibility; contrast preserved in selection/dark/
  increase-contrast.
- Dock badge = count of attention agents on the selected host, independent of
  windows/filters/focus; zero clears. Routed through AppDelegate's badge writer;
  attention count takes precedence over the bell count.
- Agents ▸ Jump to Next Needing Attention (proposed ⌃⌥⌘J): unfiltered sidebar
  order, starts after the focused agent (else selected row), wraps once, skips
  the focused identity. Reveals sidebar and clears a hiding filter; selection
  updates only after attach succeeds.

## Notifications and focus identity

- Agents ▸ Agent Notifications… enables; request `.alert` only on explicit
  enable; on denial show System Settings instructions once.
- Notify on committed live transitions into needs_input or finished, once per
  (host, agent, revision). No catch-up after startup/recovery/permission change.
  No error notifications in this scope.
- `AttachTabHost` gains focused-handle lookup + change events;
  `GhosttyAttachTabHost` derives it from key window → selected tab →
  `focusedSurface`. `LeoAttachCoordinator` maps handle → identity via
  `identityByHandle`. Never infer identity from titles or sidebar selection.
  Any focused attachment of the same identity suppresses; suppressed
  transitions are consumed, not deferred.
- Ordinary `.active` UserNotifications, no time-sensitive level, no bounce;
  DND handled by the system. Title = agent + host; body "Needs your input" /
  "Finished"; no terminal text. Namespaced identifiers; click attaches/focuses.

## Files

- Add `Attention/LeoAttentionReducer.swift`, `Attention/LeoAttentionController.swift`.
- Change `Observe/LeoActivityClient.swift`, `Observe/LeoSocketActivityClient.swift`,
  `Sidebar/LeoSidebarFeed.swift`, `LeoSidebarState.swift`, `LeoSidebarReducers.swift`,
  `Sidebar/LeoAgentRow.swift`, `LeoStatusPresentation.swift`,
  `Attach/AttachTabHost.swift`, `GhosttyAttachTabHost.swift`, `LeoAttachCoordinator.swift`,
  `LeoRuntime.swift`, `Integration/LeoAgentMenuActions.swift`, `LeoMenuCommands.swift`,
  `App/AppDelegate.swift`, `MainMenu.xib`.
- Tests: `LeoAttentionReducerTests.swift` (scripted traces, injected clock),
  `LeoAttentionIntegrationTests.swift` (fake daemon via `UnixSocketTestServer`:
  two agents, focused suppression, one background notification, jump, reconnect
  without duplicates).
- Leo daemon: `internal/observe/{event,snapshot}.go`, projection, harness
  producers, contract tests.

## Open questions for Evan

1. Count finished/errored until work resumes, with no "read" acknowledgment?
   (Orchestrator recommends: focusing the agent's tab acknowledges it for the
   Dock count; the row badge stays.)
2. Treat a focused split as "viewing the agent"? (Recommend yes.)
3. ⌃⌥⌘J for Jump? (Recommend yes.)
