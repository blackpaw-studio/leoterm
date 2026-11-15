# Leo Chat: full messages + iMessage-style layout

Platforms: **both** (Mac + iOS). The layout rules are pure logic, so they go in LeoKit.
Drawing stays per platform: SwiftUI on Mac, UIKit on iOS.

## Goals
1. Never collapse anything. Every message shows its full content.
2. The transcript reads like iMessage: time headers after gaps, grouping by sender,
   tails on bubbles, and solid "mine" bubbles.

## 1. Remove collapsing
- Delete the `isLong` gate, the 600-char / 12-line limits and the "Show more/less" button on both
  platforms: Mac `LeoChatExpandableText`, iOS `ChatMessageCell`.
- Task cards also always render in full. The one-line collapsed mode and its toggle go away.
- Delete the expand state end to end: Mac `LeoChatPaneModel.expanded`, iOS `ChatThread` state, action
  and reducer cases. Also delete the duplicated limit constants, and the tests that only covered
  collapse (the `isLong` thresholds and the expand toggle).
- Voice transcripts and attachment transcripts that reuse the expandable view also render in full.

## 2. Shared timeline layout (LeoKit)
New pure function `LeoChatLayout.items(for messages: [LeoChatMessage], calendar:, now:) -> [LeoChatLayoutItem]`.
It assumes messages are sorted by `(ts, id)`. `calendar` and `now` are injected so tests can control them.

`LeoChatLayoutItem` is one of:
- `.timeHeader(Date)`: emitted before the first message, and before any message whose `ts` is at
  least **15 min** (`timeHeaderGap`) after the previous message.
- `.message(LeoChatMessage, position: GroupPosition)`, where `GroupPosition` is one of `single`,
  `first`, `middle`, `last`.

Grouping rule: consecutive bubble messages are in the same group when all of these hold:
- they have the same `direction`;
- no time header falls between them;
- the gap between them is under 60 s (`groupGap`);
- both are bubble kinds (text, voice, file, ask, permission).

`system` and `task` messages are never grouped. They always get `.single`, and they break the
group around them.

The existing `continuesPost` behaviour (an ask that continues the agent's previous post) is kept
as-is and composes with grouping. A continued ask counts as `middle`/`last` of that group.

Header text: `LeoChatLayout.headerText(_ date:, calendar:, now:)`, following iMessage:
- today: "Today 1:06 PM"
- yesterday: "Yesterday 9:12 AM"
- within the last 6 days: "Tuesday 3:00 PM"
- same year: "Thu, Oct 3 at 2:00 PM"
- older: "Oct 3, 2025 at 2:00 PM"

Use the locale-aware `Date.FormatStyle` for these, not hard-coded format strings.

## 3. Visuals (per platform, matched)
- **Spacing:** 2 pt between bubbles in a group, 10 pt between groups, 16 pt around a time header.
- **Time header:** centred, caption size, secondary colour. The day part is semibold, as in iMessage.
- **Tails:** only `single` and `last` bubbles get a tail, on the sender's side at the bottom corner.
  `first` and `middle` bubbles get a smaller radius on the inner side next to their neighbour,
  like iMessage. One shared shape spec: the radius values and the tail geometry are in the plan.
- **Mine bubbles:** solid accent fill with white text. Links, inline code, and file chips inside
  mine bubbles must stay legible: white or underlined links, and a translucent white code background.
  Agent bubbles do not change.
- **Per-bubble time footer:** kept for now (not removed), shown only on `single`/`last` bubbles,
  so a group has one time.
- Ask, permission and file bubbles get the same tail and grouping treatment. Task cards and
  system notes stay full-width or centred, with no tails.

## Testing
- LeoKit unit tests for `items(for:)`: header at the start; header after a ≥15 min gap, none after
  14:59; group splits on a direction change, a ≥60 s gap, a header, or a system/task message
  between; positions single/first/middle/last; a `continuesPost` ask inside a group.
- LeoKit tests for `headerText` covering each of the five date buckets, using a fixed calendar,
  time zone and locale.
- The views are UI styling, so they are exempt from TDD. Verify them with screenshots of the real
  Mac and iOS apps (simulator) on a thread that has a gap, a group, a long message (>12 lines),
  and a task card. Include both light and dark mode for the solid mine bubble.

## Out of scope
Hover/swipe-to-reveal exact times, read receipts, reactions, typing indicators.
