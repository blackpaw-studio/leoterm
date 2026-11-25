# Needs-you Inbox — Spec

Date: 2026-11-24 · Status: draft for approval · Platforms: **both** (logic in LeoKit, UI per app)
Mockups: `docs/mockups/2026-11-24-inbox/` (Mac option A + iOS are the approved direction)

## Problem

Evan runs many agents across projects and machines and loses track of (1) what is waiting on him,
(2) what finished, and (3) where each thread stands. This spec covers (1) and (2). Project grouping
and a per-agent "where was I" brief are later, separate specs; this design must leave room for them.

## Model (LeoKit)

One `InboxItem` per agent, derived, never authored:

- **Blocked:** the agent's attention state is `needsInput`. Kinds:
  - `chatAsk`: an open `leo_chat_ask` (`LeoChatMessage.isOpen`). Carries the question, the input
    spec (buttons/radio/checkboxes/text, allow_text), and the agent's last chat message before the
    ask as context when one exists in already-fetched chat history (no daemon change for this).
  - `permission`: a terminal permission prompt. Carries the tool name and command/summary when the
    daemon exposes it; otherwise the attention reason text.
  - `question`: AskUserQuestion / elicitation. Carries the question text when available.
- **Finished:** attention state `finished` or `errored` with activity newer than the agent's
  `lastSeenAt`. Carries a one-line result (last turn preview / error summary) and an error flag.
- Every item carries agent name, machine, project label, and timestamp (age).
- Project label is omitted when it equals the agent name.
- Ordering: Blocked oldest-first; Finished newest-first.
- Items from all connected machines are merged. A disconnected machine's items drop out (no stale
  items); they reappear on reconnect.

## Read state (synced)

- Per-agent `lastSeenAt`, shared between Mac and iOS. Opening an agent (chat, terminal, or its
  inbox detail) sets it to now. "Clear" / "Clear Finished" sets it for every finished item shown.
- Blocked items are never cleared by viewing; they leave when the agent leaves `needsInput`.
- Storage: reuse the existing synced unread mechanism (`LeoChatUnreadCounts`) if it can carry this;
  otherwise a daemon change via PR reviewed and merged by the `leo` agent. The plan must decide.

## Mac (option A)

- Sidebar gets a pinned **Inbox** row under the search field. Selecting it shows the inbox in the
  main content area (no separate window).
- Badge: orange count of Blocked items; when zero Blocked but ≥1 unread Finished, a grey dot; none
  when empty.
- Inbox = list + detail. Header: title, summary ("3 need you · 3 finished since you looked"),
  filter (All / Needs you / Finished), Clear Finished.
- List sections: NEEDS YOU, then FINISHED SINCE YOU LOOKED (with Clear). Unread finished rows show a
  blue dot.
- Detail:
  - `chatAsk`: context bubble + the existing questions card (`LeoChatQuestionsCard`), answered
    inline; Submit sends via the same path as the chat pane. Plus Open Chat / Go to Agent.
  - `permission` / `question`: the text (and command in mono) plus **Go to Agent**; no inline answer.
  - Finished: result line and Go to Agent; selecting marks it seen.
- Keyboard: ↑/↓ move, ↩ submit, ⌘↩ go to agent, ⌫ clear finished item.
- Empty state: "You're all caught up" with running-agent count.

## iOS

- Existing Chats screen and chips (All / Needs you / Working / Done). **Errored moves from Needs you
  to Done.**
- Needs you cards show the full question: buttons for single-choice asks, inline reply field for
  text asks, "Reply instead" / "Open chat" links; permission shows the command + **Go to agent**.
- Done shows "Since you looked" (unread dot, Clear) then "Earlier".
- Chats tab badge follows the Mac badge rule.
- Empty state: "Nothing needs you".

## Out of scope

Inline approve/deny of permission prompts or AskUserQuestion (needs a daemon hook relay); project
grouping; where-was-I brief; cross-agent threads; snooze/archive; push-notification changes.

## Acceptance

- An open chat ask on any machine appears in both apps' inbox within one event-stream update and can
  be answered there; the agent receives the answer exactly as if answered in its chat pane.
- A permission prompt appears with its text and Go to Agent opens that agent.
- Opening an agent on Mac clears its finished item on iOS (and vice versa).
- Badge rules hold on both platforms; errored is under Done on iOS.
- Derivation, ordering, read-state, and badge logic are unit-tested in LeoKit.
