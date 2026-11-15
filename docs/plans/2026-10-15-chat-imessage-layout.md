# Plan: full chat messages + iMessage-style layout

Spec: `docs/superpowers/specs/2026-10-15-chat-imessage-layout.md` (source of truth). Platform: **both**. The grouping, header text, bubble
geometry and spacing are pure logic, so they go in LeoKit and both apps read the same numbers. Drawing stays per platform:
SwiftUI on Mac, UIKit on iOS.

## Verified facts the steps rely on
1. Both platforms already sort messages by `(ts, id)`: Mac `LeoChatTimeline.swift:58`, iOS `ChatThread.swift:72-79` (`merge` → `messages.sort`).
   Either array can go straight into the layout function.
2. **The name `LeoChatLayout` is taken.** It is the Mac Terminal/Chat split enum (`macos/…/Chat/LeoChatLayout.swift:14`, used across the app and
   `LeoChatLayoutTests`). An app-local type shadows an imported one, so the LeoKit type is named **`LeoChatTranscript`**. Only the name differs from the spec.
3. `continuesPost(after:)` (`LeoChatAsk.swift:222-226`) also accepts a `.task` predecessor. Tasks never group, so an ask that continues a task card
   is `single`/`first`, and it keeps today's tight look (4 pt under the card; Mac had 10 − 6).
4. The composer reply banner still uses `LeoChatPresentation.firstLine` (`LeoChatComposer.swift:98`), so it stays.
5. The iOS bubble body is a plain-text `UILabel` (`ChatMessageCell.swift:122`), with no Markdown. On iOS, legibility therefore means the colours of the text,
   footer, file chip and voice chip.
6. Only two tests cover collapsing: Mac `LeoChatPaneModelTests.swift:585-590` (`longRepliesCollapse`) and iOS `ChatThreadTests.swift:572-576`
   (`showMoreAndTaskCardsToggleExpansion`). No UI test depends on "Show more" or on cell order.
7. The footer carries "Sending…" and "Not delivered" (Mac `LeoChatMessageRow.swift:63-75`; iOS `ChatPresentation.stateLine`). Hiding those on
   `first`/`middle` bubbles would hide failures (see Risks).
8. The daemon's chat store is SQLite at `<home>/state/chat.db`, table `messages`, with `messageColumns` from leo `internal/chat/store.go:167`
   and `ts INTEGER`. Step 8 uses this for seeding.

## Shared geometry and spacing (LeoKit; all values in pt, CGFloat/CGPoint via Foundation)
`LeoChatBubbleGeometry`:
- `cornerRadius = 17` and `groupedCornerRadius = 5`. Each is clamped to `min(value, height/2, width/2)`.
- Corners by position. S is the sender side, O the other side, and both O corners are always 17.
  - `single`: S-top 17, S-bottom **tail**
  - `first`: S-top 17, S-bottom 5
  - `middle`: S-top 5, S-bottom 5
  - `last`: S-top 5, S-bottom **tail**
- Tail. The coordinates below are for a trailing (mine) bubble with body maxX = X and maxY = Y; a leading bubble mirrors x about the rect's midX.
  The tail sits outside the body rect, so body edges line up across a group.
  1. The bottom edge runs to `(X−13, Y)`.
  2. Cubic to the tip `(X+4, Y)`, with c1 `(X−3.6, Y)` and c2 `(X−0.1, Y−2)`.
  3. Cubic to `(X, Y−11)`, with c1 `(X−0.7, Y−1.3)` and c2 `(X, Y−4.7)`.
  4. The side edge runs up to the S-top corner. That corner's radius is also clamped to ≤ `height − 11`.
  - Constants: `tailWidth = 4`, `tailBaseInset = 13`, `tailRise = 11`. The tail lands inside the existing 12 pt side margins on both platforms.
- `outline(in: CGRect, side: Side, position: GroupPosition) -> [Element]`
  - `Side` is `.leading` or `.trailing`.
  - `Element` is one of `.move(CGPoint)`, `.line(CGPoint)`, `.curve(to:c1:c2:)`, `.corner(tangent1End:tangent2End:radius:)`, `.close`.
  - Each platform maps it in about 10 lines: SwiftUI `Path` on Mac, `CGMutablePath` on iOS. Both use `addArc(tangent1End:tangent2End:radius:)`, so the corners match exactly.

`LeoChatTranscript.spacing(above: Item, after previous: Item?) -> CGFloat`:
- 0 for the first item
- 16 when either item is a time header (16 above and 16 below)
- 2 for a `middle`/`last` message
- 4 for an ask that continues a task card
- otherwise 10

## Test commands
- **LeoKit:** `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer swift test --package-path Packages/LeoKit [--filter <Suite>]`,
  then `(cd Packages/LeoKit && swiftlint lint --strict)`.
- **Mac** (builds, runs every GhosttyTests test, then swiftlint): first check `pgrep -fl "Leo -XCTest"` is empty, then `bash macos/scripts/leo-runtests.sh imsg-<step>`.
  Never run two suites at once.
- **LeoFeatures:** `cd ios/LeoFeatures && DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer swift test`.
- **iOS app:** run `cd ios && xcodegen generate`. Then run both of the following with `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer -project Leo.xcodeproj -scheme Leo
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" -derivedDataPath "$TMPDIR/dd-leo-ios"`:
  - `xcodebuild build-for-testing CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`
  - `xcodebuild test-without-building`
- **Commit rule:** every commit keeps LeoKit and LeoFeatures green and the Mac building.

## Step 1: LeoKit grouping (`LeoChatTranscript.items`)
Files: new `Packages/LeoKit/Sources/LeoKit/Chat/LeoChatTranscript.swift`. Interface (pure, `Sendable`):
```swift
public enum LeoChatTranscript {
    public static let timeHeaderGap: TimeInterval = 15 * 60
    public static let groupGap: TimeInterval = 60
    public enum GroupPosition: Equatable, Sendable { case single, first, middle, last }
    public enum Item: Equatable, Identifiable, Sendable {
        case timeHeader(Date, id: String)                 // id "time-<next message id>"
        case message(LeoChatMessage, position: GroupPosition)
        public var id: String { get }                     // message: message.id
    }
    public static func items(for messages: [LeoChatMessage]) -> [Item]   // input sorted by (ts, id)
}
```
Rules:
- A header goes before message i when i == 0 or `ts[i] − ts[i−1] ≥ 900 s`.
- `joinsPrevious` holds when all of these are true:
  - there is no header before i;
  - both messages are bubble kinds (text, voice, file, ask, permission; `.unknown` is not);
  - the directions match;
  - the gap is under 60 s **or** `m.continuesPost(after: prev)`.
- Position comes from `(joinsPrevious, nextJoins)`: (no, no) is `single`, (no, yes) `first`, (yes, yes) `middle`, (yes, no) `last`. Built with map, no mutation.
- **Deviation:** `items` takes neither `calendar` nor `now`. Gaps are absolute durations, so they are needed only by `headerText` (Step 2).

Failing tests first, in new `Packages/LeoKit/Tests/LeoKitTests/LeoChatTranscriptTests.swift` (Swift Testing). The local factory takes `(id, kind, direction, offset seconds)` from a fixed base `Date`.
- empty input gives `[]`
- a header comes before the first message
- a header follows a 900 s gap; there is none at 899 s
- a direction change splits a group
- 59 s groups and 60 s splits
- a system or task message between two texts gives single/single/single
- four quick same-direction texts give first/middle/middle/last; a lone text is single
- an ask that continues a text 120 s later gives first/last
- a header between a text and its continuing ask splits them
- an ask that continues a task card stays single
- `.unknown` is single
- item ids are unique and stable: the header id is `time-<next id>`

Verify: run LeoKit with `--filter LeoChatTranscriptTests`, then the full LeoKit suite and swiftlint. Commit: `feat: LeoKit groups chat messages and places time headers`.

## Step 2: LeoKit header text
Same file. Add:
```swift
public struct HeaderText: Equatable, Sendable { public let day: String; public let time: String; public let text: String }
public static func headerText(_ date: Date, calendar: Calendar, now: Date) -> HeaderText
```
- Locale and time zone come from `calendar.locale` and `calendar.timeZone`. Production passes `.autoupdatingCurrent`; tests inject clock, calendar and locale.
- Buckets are by calendar-day difference between the start-of-day of `date` and of `now`:
  - 0 → `String(localized: "Today")`
  - 1 → `String(localized: "Yesterday")`
  - 2…6 → `.weekday(.wide)`
  - same year → `.weekday(.abbreviated).month(.abbreviated).day()`
  - otherwise → `.month(.abbreviated).day().year()`
- `time` comes from `Date.FormatStyle(date: .omitted, time: .shortened, locale:calendar:timeZone:)`.
- `text` is `"\(day) \(time)"` for the first three buckets and `String(localized: "\(day) at \(time)")` for the dated two.
  Platforms make the day semibold by finding `day`'s range in `text`.

Failing tests first, same file, in a separate suite `LeoChatHeaderTextTests`:
- Setup: Gregorian calendar, `America/New_York`, `en_US`, now = Thu 2026-10-15 13:30.
- Expected strings use `\u{202F}` before AM/PM, which current ICU emits:
  - `Today 1:06 PM`
  - `Yesterday 9:12 AM`
  - Tue 10-13 gives `Tuesday 3:00 PM`
  - Fri 10-09, 6 days back, gives the `Friday …` bucket
  - Thu 10-08, 7 days back, gives `Thu, Oct 8 at …`
  - Thu 10-01 gives `Thu, Oct 1 at 2:00 PM`
  - 2025-10-03 gives `Oct 3, 2025 at 2:00 PM`
- 23:55 the previous day with now = 00:10 gives `Yesterday` (the bucket is by calendar day, not 24 h).
- `day` equals the expected day part in each case.

Verify: LeoKit `--filter LeoChatHeaderTextTests`, then the full suite. Commit: `feat: LeoKit formats iMessage-style chat time headers`.

## Step 3: LeoKit bubble geometry and spacing
Files: new `Packages/LeoKit/Sources/LeoKit/Chat/LeoChatBubbleGeometry.swift`, holding the constants and `outline` from the section above, plus `LeoChatTranscript.spacing`.
Failing tests first, in new `LeoChatBubbleGeometryTests.swift`:
- a trailing `last` bubble in (0,0,200,40) has its tip exactly at (204, 40) and the cubic control points as specified
- a leading `single` bubble mirrors it, with the tip at (−4, 40)
- `first` and `middle` outlines have no point outside the rect
- `middle` uses radius 5 on both sender-side corners and 17 on the other side
- a 30 pt-high bubble clamps 17 → 15
- the spacing table: first item 0, header 16 above and below, in-group 2, ask continuing a task card 4, group break 10

Verify: LeoKit filter, then the full suite and swiftlint. Commit: `feat: LeoKit shares chat bubble geometry and spacing`.

(After Step 3, the Mac track (4 → 6) and the iOS track (5 → 7) touch disjoint files. Run them in parallel only from separate worktrees.)

## Step 4: Mac, remove collapsing (removal; UI, exempt, screenshot verify in Step 8)
- `LeoChatPaneModel.swift`: delete `expanded` (:34-35), its resets (:94, :143) and `toggleExpanded` (:147-149).
- `LeoChatPresentation.swift`: delete `collapsedCharacters`, `collapsedLines` and `isLong` (:7-13). Reword the `firstLine` doc so it names the reply banner.
- `LeoChatMessageRow.swift`:
  - delete `isExpanded` (:13)
  - replace `LeoChatExpandableText` with `LeoChatMarkdownText(text:)`: no id, no chat, no `lineLimit`, no button
  - `LeoChatTaskCard` always shows its header row (icon, task name, time), the full text, attachments and Reply; the chevron and toggle go
- `LeoChatAttachmentView.swift:131`: the voice transcript uses `LeoChatMarkdownText`.
- `macos/Tests/Leo/LeoChatPaneModelTests.swift`: delete `longRepliesCollapse` (:586-590).
Verify: `leo-runtests.sh imsg-4`, and `rg -n "isLong|expanded|toggleExpanded|collapsed" macos/Sources/Features/Leo/Chat` is empty.
Commit: `refactor: Mac chat shows every message and task card in full`.

## Step 5: iOS, remove collapsing (removal; UI, exempt)
- `ChatThread.swift`: delete `expanded` (:34-35), `Action.expandToggled` (:104), the reducer case (:232-234) and the reset in `taskFilterChanged` (:303).
- `ChatThreadTests.swift`: delete `showMoreAndTaskCardsToggleExpansion` (:572-576).
- `ChatPresentation.swift`: delete `collapsedCharacterLimit`, `collapsedLineLimit` and `isLong`.
- `ChatMessageCell.swift`: delete `Event.expand` and `Model.isExpanded`. Lines :126-133 become `body.numberOfLines = 0` with no Show/Show more button.
  Task cards keep the header, the full body and Reply.
- `ChatThreadViewController.swift`: drop `isExpanded:` (:110) and the `.expand` case (:236-237).
Verify: LeoFeatures `swift test`, then iOS build-for-testing and test-without-building. Commit: `refactor: iOS chat shows every message and task card in full`.

## Step 6: Mac transcript (UI styling; exempt, screenshot verify)
- New `macos/…/Chat/LeoChatBubbleShape.swift`: `struct LeoChatBubbleShape: Shape { side; position }`, which maps `LeoChatBubbleGeometry.outline` to `Path`.
- New `macos/…/Chat/LeoChatTimeHeader.swift`: centred `.caption` text in `.secondary`, with the `day` range semibold via `AttributedString`, and
  `accessibilityIdentifier("chat.timeHeader")`.
- `LeoChatThreadView.swift`:
  - change to `LazyVStack(spacing: 0)` and loop with `ForEach(Array(items.enumerated()), id: \.element.id)` over `LeoChatTranscript.items(for: chat.timeline.messages)`
  - each item gets `.padding(.top, LeoChatTranscript.spacing(above:after:))`
  - delete `continuationOverlap` (:13, :26)
  - add `@State now`, refreshed on `.NSCalendarDayChanged` and `.NSSystemTimeZoneDidChange`; the calendar is `.autoupdatingCurrent`
- `LeoChatMessageRow(message:position:chat:)`:
  - The bubble background becomes `LeoChatBubbleShape(side: isMine ? .trailing : .leading, position:)`.
  - **Mine bubbles:** solid `Color.accentColor` fill, with `.foregroundStyle(.white)` and `.tint(.white)` on the content.
    - Attachment subtitles use hierarchical `.secondary`, so they inherit the white; the voice button and progress take the tint.
    - `LeoChatMarkdownText(text:isMine:)` underlines `.link` runs. Runs whose `inlinePresentationIntent` contains `.code` get `backgroundColor = .white.opacity(0.22)`.
  - **Agent bubbles:** same fill. The stroke becomes `.stroke(separator.opacity(0.6), lineWidth: 1)` on the shape.
  - **Footer:**
    - time and "Delivered" only on `single`/`last`
    - "Sending…" and "Not delivered" at any position
    - nothing else on `first`/`middle`, so in-group spacing stays 2
  - Task cards and system notes are unchanged: no tails.
Verify: `leo-runtests.sh imsg-6` (build, all tests and swiftlint clean). Commit: `feat: Mac chat reads like iMessage (headers, groups, tails, solid mine bubbles)`.

## Step 7: iOS transcript (UI styling; exempt, screenshot verify)
- New `ios/Leo/Chat/ChatBubbleView.swift`:
  - a `UIView` with `layerClass = CAShapeLayer`, and `style: .bubble(side, position) | .card(radius: 18) | .plain`
  - the path is built from `outline` in `layoutSubviews`
  - `fillColor` is resolved against `traitCollection` there; `registerForTraitChanges([UITraitUserInterfaceStyle.self])` calls `setNeedsLayout`
  - no `masksToBounds`, so the tail draws into the 12 pt margin
- New `ios/Leo/Chat/ChatTimeHeaderCell.swift`: a centred caption1 label in `secondaryLabel` with the `day` range semibold, and
  `accessibilityIdentifier = "chat.timeHeader.<id>"`.
- `ChatMessageCell.swift`:
  - `bubble` becomes a `ChatBubbleView`
  - `Model` replaces `continuesPost` with `position` and `topSpacing: CGFloat`; `top.constant = topSpacing`, and the bottom constant changes from −3 to 0
  - **Mine:**
    - `.tintColor` solid fill, body `.white`, footer white at 0.8
    - file and voice chips: `.plain()` config with `baseForegroundColor .white` and background `white.withAlphaComponent(0.2)`
    - the "no longer stored" label is white at 0.8
  - Agent bubbles are unchanged. The footer rule matches Step 6.
- `ChatThreadViewController.swift`:
  - snapshot ids come from `LeoChatTranscript.Item.id`
  - `render()` computes `items(for: Array(store.messages))` and keeps `shownItems: [String: Item]` plus each item's spacing
  - two registrations, header and message, chosen per item
  - previously shown ids are still reconfigured each render, so positions update when a message lands
  - `prepended`/`scrollToBottom` use item ids (the last item is always a message); `willDisplay` handles only message items
  - `UIApplication.significantTimeChangeNotification` reconfigures the header items
Verify: LeoFeatures `swift test`, then iOS build-for-testing and test-without-building. Commit: `feat: iOS chat reads like iMessage (headers, groups, tails, solid mine bubbles)`.

## Step 8: Final verification (real apps, light and dark)
**Seed.** Run an isolated daemon following the `isolated-leo-daemon-recipe` memory (`-c`, scratch cwd, `TMUX_TMPDIR`, short socket path) and create `autopilot-scratch`.
Stop the daemon, then insert rows into **its** `state/chat.db` `messages` table. Never touch the production `~/.leo` store. Before writing, check the columns
(`store.go:167`), the `ts` unit, the `direction`/`kind` encodings and the ULID format. Keep it under 50 rows, so everything lands on one page. Rows, in local time:
1. Yesterday 09:12: an agent text, which gives the "Yesterday" header.
2. Today, T−40 min:
   - agent text ×3, 20 s apart (first/middle/last)
   - then user text ×2, 10 s apart: one has a link and `inline code`
   - a user file message, if seeding attachment rows is simple; otherwise note it as unverified
3. Today, T−20 min (a ≥15 min gap, so a header):
   - a 30-line agent text (>12 lines)
   - an agent file 20 s later
   - an ask continuing it 90 s later (still `last`)
   - a task card, an ask continuing the card, and a system note
4. Start the daemon.

**Mac.** Follow `.autopilot/verify.md`: debug bundle `studio.blackpaw.leo.macos.debug`, Peekaboo with `--bridge-socket` and `--capture-engine cg`.
- Select scratch, then Chat. Take light shots, scrolling as needed to show the header, the groups, the full long message and the task card.
- Relaunch with `-AppleInterfaceStyle Dark` for the dark shots. Never flip the system setting.
- Never press Return. Quit with `pkill -f` on the debug binary path.

**iOS.** Use the simulator paired to the isolated daemon (as in `2026-10-12-chat-ask-inputs-clients.md`).
Switch with `xcrun simctl ui booted appearance light|dark` and capture with `xcrun simctl io booted screenshot <png>`.

**Inspect at native pixels:**
- the tip sits 4 pt outside the body, body edges line up within a group, and grouped corners are 5 against 17 outer
- spacing is 2/10/16, with the 4 pt ask under the task card
- the footer appears only on the last bubble of a group
- links stay legible and underlined in mine bubbles, with a translucent code background
- no "Show more" anywhere, and the task card is full with Reply
- the dark solid bubble is legible

**Clean up.** Delete scratch, stop the isolated daemon, and return the PNG paths for the orchestrator to post.

## Risks and open questions
- **Naming:** `LeoChatTranscript` replaces the spec's `LeoChatLayout`/`LeoChatLayoutItem` because of the Mac clash (fact 2). The behaviour is as specified.
- **`items(for:)` signature:** it drops `calendar` and `now` (YAGNI; only `headerText` needs them). Open: should a day boundary force a header when the gap is under 15 min
  (23:55 → 00:05)? The spec says no, and the plan follows it.
- **Footer deviation:** "Sending…" and "Not delivered" stay visible on `first`/`middle`. Hiding a failure is worse than a second footer. Time and "Delivered" follow the spec.
- **Continued ask:** it joins the previous group even past 60 s (the spec's "counts as middle/last"). A header between them still splits.
- **Header spacing:** "16 pt around a header" is read as 16 above and 16 below. If it looks loose, it is one constant to change.
- **ICU spacing character:** ICU emits U+202F before AM/PM, and the tests assert it. A future ICU change breaks only the header tests.
- **Stale "Today":** "Today" stays correct only through the day-change and time-zone notifications. That covers midnight; a missed one fixes itself on the next render.
- **iOS dark mode:** CAShapeLayer colours don't follow trait changes on their own. They are resolved in `layoutSubviews` plus the trait registration; the dark screenshot checks it.
- **Mac radius:** bubbles move from 12 → 17, clamped to height/2, and iOS from 18 → 17. This is deliberate, so both platforms share one shape. Task-card radii stay per platform (10 and 18).
- **Mac stroke:** the agent-bubble stroke changes from an inset `strokeBorder` to a centred stroke, which sits 0.5 pt outside the body; at 1 px it is not noticeable.
- **`.unknown` kind:** treated as never grouped, so it is `single` with a tail.
- **Long threads:** full messages make long agent posts take a lot of scroll. This is accepted per spec, and `items` is O(n) over the loaded pages.
- **Seeding:** the verifier writes SQLite directly, and only into the isolated daemon's store.
