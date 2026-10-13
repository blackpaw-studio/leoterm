# Spec: Mac chat unread badges + auto-open on asks

**Platform call:** Mac only. Unread counting goes in LeoKit as a plain value type so iOS can use it later. iOS already badges its chat list and tab from `ChatList.unreadTotal`. Moving iOS onto the shared type goes to the autopilot backlog.

## Goal
On the Mac, show how many unread agent messages each agent has, and switch to Chat when the agent in view needs an answer.

## Behavior

### Unread counts
- An agent's unread count is the number of chat messages **from the agent** after the daemon's read mark. On the wire that is `direction: out` (`.outbound` in LeoKit). Your own messages (`in`) never count.
- **Seed:** on connect and on every resync (`hello`/`gap`/`snapshot`), counts come from `LeoChatClient.threads()` (`unread`). Daemon state wins. History loaded on launch never shows up as new.
- **Live:** each agent-sent `chat.message` event adds 1 to its agent's count, for every agent on the host, not only the selected one. The exception is when that agent's chat is on screen in any window. The pane then calls `markRead` and the count stays at 0.
- **Clear:** when an agent's chat pane comes on screen and `markRead` succeeds, that agent's count goes to 0. This is the existing `markRead` path (`LeoChatPaneModel.swift:190`), and it runs only with no task filter.
- One store per runtime/host, keyed by agent. It is fed from the `LeoRuntime` chat relay, upstream of `LeoChatPaneModel`'s selected-agent guard.

### Badges
- **Chat segment:** the Terminal | Chat switch in the control bar shows the selected agent's unread count as a small count capsule. It is hidden at 0 and while Chat is the visible view. Counts above 99 show as `99+`.
- **Sidebar rows:** each agent row shows its unread count as a count capsule at the end of the name line. The leading attention symbol stays as it is. The two stay independent: attention is agent state, unread is chat messages. The Dock count is unchanged.
- Badge styling follows existing Mac conventions (system accent capsule, monospaced digits, light and dark modes).

### Auto-open
- Trigger: a **live** agent-sent message with `kind` `ask` or `permission` and `state == "open"`, from the agent that is selected in a window.
- Effect: in every window where that agent is selected and Terminal is the current choice, call `LeoWindowSession.choose(.chat, for:)`. Keyboard focus follows the existing chat focus rules.
- It does **not** activate or raise the app, and it does not change the selected agent.
- It never fires for messages loaded by seed, resync, or history paging. It never fires for text, file, voice, task, or system messages; those only add to the badge.
- If chat is already visible (chat view or side-by-side layout), nothing changes.

## Out of scope
- App-icon or Dock count for chat unread.
- Auto-opening for agents that aren't selected, or changing the selection.
- Changes to iOS UI (backlog item above).
- Daemon changes. The existing `threads()` and `markRead` contract is enough.

## Testing
- LeoKit unit tests for the unread store: seed, agent-message increment, user messages ignored, on-screen suppression, clear on read, resync re-seed overwrites live counts.
- Mac tests for the auto-open decision: open ask or permission from the selected agent → chat; other kinds, other agents, resync or history, or chat already visible → no switch.
- Badge visuals are verified with a screenshot of the running debug app, not unit tests.
