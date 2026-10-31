# Leo iOS — chat first, management second

Status: draft for approval · 2026-10-30
Platform call: **iOS only.** The Mac app is a terminal-first window manager; its sidebar
already is the management UI and has its own chat pane. Nothing here moves into LeoKit
unless the plan finds an existing LeoKit type that needs a field.
Mockups: https://claude.ai/artifact/8Sf4U8DJdLCzpoQhJ6GqYx (concept A screens, concept C's
terminal strip).

## Goal

Opening the app lands you in conversations with your agents, with the ones that need you
on top. Fleet management (agents, machines, pairing, tasks, config) stays fully available
but one tab away.

## 1. Root: tab bar

- Root becomes a `UITabBarController` with four tabs, in order: **Chats · Agents ·
  Machines · Settings**. Chats is selected on launch.
- **Chats**: the inbox below. On iPad (regular width) it is a split view: inbox | thread.
- **Agents**: today's agents list and agent detail, unchanged apart from removing the
  Chats nav-bar button (the tab replaces it). iPad keeps its list | detail split.
- **Machines**: today's Machines/Daemons screen, with Pair reachable from it.
- **Settings**: today's Settings screen, plus the new Chat section (§4).
- Chats tab badge = existing `ChatList.State.unreadTotal`; no badge at 0.
- Deep links and push-notification taps that open a chat switch to the Chats tab and open
  that thread. Anything that opened agent detail switches to Agents.

## 2. Chats inbox

- One row per chat thread (existing `ChatList` data). Each row shows: agent avatar
  (existing appearance color/icon), a status dot, agent name, time of last message,
  last-message preview, unread badge, and the daemon name when more than one daemon is
  paired (as today).
- Rows carry the agent's status via the existing join `AgentRef → fleet session → Agent`.
  A thread whose agent is not in the fleet shows no dot and sorts as idle.
- Status buckets (from `Agent.priority`):
  - **Needs you**: `needsInput`, `errored` — orange dot; preview prefixed "Asks:" or
    "Error:" in the accent-orange text.
  - **Working**: `working` — blue dot.
  - **Done**: `finished` — green dot.
  - Other (`idle`, `stopped`, unknown): no dot.
- Sort: Needs you first, then Working, then everything else; within a bucket, newest last
  message first. `assistant` stays pinned to the top of its bucket, not above Needs you.
- Filter chips under the large title + search: **All · Needs you (n) · Working (n) ·
  Done**. Counts shown on Needs you and Working when > 0.
- Default chip: **Needs you** when its count > 0 at launch, otherwise **All**. A chip the
  user picks sticks until the app is relaunched. When the selected chip's list becomes
  empty, show an empty state with an "All chats" button, never auto-switch.
- Search field filters by agent name and last-message text (client-side, current rows).
- New chat (compose button, top right) keeps today's running-agent picker.

## 3. Chat thread

- Header: back, centered avatar + agent name + status line ("Needs input · dionysus"),
  and two trailing icon buttons: **Terminal** (opens today's full terminal screen) and
  **Info** (opens today's agent detail). Both have accessibility labels.
- Ask cards: today's `ChatQuestionsCard` controls, restyled so single-choice button asks
  render as full-width stacked buttons (first option filled accent, others tinted), with
  a quiet "Reply instead" that focuses the composer. Radio, checkbox and text asks keep
  their controls; only spacing and sizing change to match. Behavior and wire format
  unchanged.
- Composer, attachments, time headers, bubbles: unchanged.

## 4. Live terminal strip

- A compact read-only strip pinned under the thread header, showing **5 lines** of the
  agent's live terminal in a monospaced font on a dark panel, with a green "Live" dot and
  the agent's state.
- Which 5 lines (amended 2026-10-31 after testing on a real Claude Code agent, where the
  bottom rows were all chrome): drop tmux's status row, find the top border of Claude
  Code's input box, and show the last 5 non-blank rows above it. If no input box is found,
  show the bottom 5 non-blank rows (tmux status row still dropped).
- Tapping the strip opens the full terminal screen.
- A **hide/show control** in the strip's title row collapses it to nothing (thread content
  moves up) and a header affordance brings it back. Animated, no layout jump in the
  message list.
- **Per-thread choice lasts only while you are in that thread.** Every time a thread opens
  it starts from the Settings default.
- **Setting** (amended 2026-10-31): Settings › Chat › "Live terminal in chats", a
  three-way choice: **While working** (default) · **Always** · **Never**, persisted with the
  existing `@Shared(.appStorage)` pattern under a new key (the old boolean key is ignored;
  it only shipped to TestFlight). Changing it affects threads opened afterwards, and the
  currently open thread if the user has not toggled it there.
- **While working**: when the user has not toggled the strip in this thread, it is shown
  exactly while the thread's agent status, as shown in the header (`Agent.priority`), is
  `working`, and appears/hides (animated) as the status changes while the thread is open.
  Any other status hides it. (An agent with unknown attention but working activity shows
  as working, so the strip shows.) Each hide drops the connection; re-showing reconnects. Once the user toggles it in a thread,
  the toggle wins until they leave the thread.
- Data: reuse the existing read-only attach (`TerminalClient.attach`); **no daemon
  changes.** Only the visible thread's strip holds a connection; it disconnects when the
  thread disappears, the strip is hidden, or the app backgrounds, and reconnects on return.
- The strip must never resize the agent's tmux window: attach at the same size the full
  terminal uses and render only the bottom rows.
- States: connecting (dim placeholder lines), live, agent not running ("Not running"),
  unreachable/error ("Terminal unavailable" + tap to retry). The strip never blocks the
  chat; failures stay inside the strip.
- Not shown when the thread's agent is unknown to the fleet.

## Out of scope

Concept B's merged single thread and `@agent` routing; app-icon badge; per-agent remembered
strip state; Mac changes; daemon/API changes; dark-mode-specific redesign (system colors
continue to drive dark mode).

## Testing

- LeoFeatures reducer tests (TCA `TestStore`): inbox bucketing and sort; default-chip rule
  and stickiness; empty-filter state; search; strip visibility (setting default, per-thread
  toggle resets on reopen, setting change applied to untoggled open thread); strip
  connection lifecycle (connect on appear when visible, cancel on hide/disappear/background).
- Tab routing: push-tap → Chats tab + thread; agent-detail link → Agents tab.
- Verification at the merge gate: simulator screenshots of the inbox (iPhone + iPad),
  thread with strip shown and hidden, and the Settings toggle, run against an isolated
  daemon with a live agent.
