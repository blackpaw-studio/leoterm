# Plan: Mac chat unread badges + auto-open on asks

Spec: `docs/superpowers/specs/2026-10-13-mac-chat-unread-badge.md` (source of truth). Platform: Mac only.
The counting value type goes in LeoKit so iOS can adopt it later.

## Verified facts the steps rely on
1. On the wire, `in` = user→agent and `out` = agent→user (leo `internal/chat/model.go:15-16`;
   Mac `LeoChatMessageRow.swift:12` `isMine = .inbound`; the daemon's `Unread` counts `out`, store_test.go:104-125).
   "From the agent" means `direction == .outbound` in code.
2. The feed forwards chat only for the **selected host** (`LeoSidebarFeed.swift:255`). "Every agent on the host" means every agent on the selected host.
3. Agent selection is app-global (`LeoSidebarModel.selection`). The single `LeoChatPaneModel` (`LeoRuntime.chat`) shows
   one agent, and its `visibleCount` already counts panes across all windows. "Chat on screen in any window" is
   therefore `chat.isOnScreen && chat.agent == X && taskFilter == nil`. The store gets this as a predicate per delivery.
4. A window shows the agent only when its own `terminals.selection == nil` (`LeoWindowSession.swift:204-207`).
5. The row's attention symbol is at the leading edge (`LeoAgentRowContent.swift:24`). The trailing edge holds the time or state word (:56-70).

## Test commands
- LeoKit: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer swift test --package-path Packages/LeoKit [--filter <Suite>]`
- Mac (builds, runs every GhosttyTests test, then swiftlint): `bash macos/scripts/leo-runtests.sh unread-<step>`.
  First check that no other host is running: `pgrep -fl "Leo -XCTest"`. Never run two suites at once.

## Step 1: LeoKit `LeoChatUnreadCounts` (value type)
Files: new `Packages/LeoKit/Sources/LeoKit/Chat/LeoChatUnreadCounts.swift`; `LeoChatModels.swift` (add
`public var isFromAgent: Bool { direction == .outbound }` next to `isOpen` :120).
Interface (immutable; every change returns a new value):
`struct LeoChatUnreadCounts: Equatable, Sendable { subscript(LeoAgentID) -> Int;
 seeding(_ threads: [LeoChatThread], host:) -> Self   // replaces all of `host`'s counts
 receiving(_ event: LeoChatEvent, host:, isOnScreen: Bool) -> Self  // +1 only for .message && isFromAgent && !isOnScreen
 clearing(_ agent:) -> Self; static func badgeText(_ count: Int) -> String? }  // nil at 0, "99+" over 99`
Failing tests first, in new `Packages/LeoKit/Tests/LeoKitTests/LeoChatUnreadCountsTests.swift` (Swift Testing):
seed sets counts per agent; an agent message adds 1 for a non-selected agent; a user (`.inbound`) message is ignored;
`.updated` is ignored; an on-screen message is suppressed; clear → 0; a re-seed overwrites live counts and leaves
other hosts alone; badgeText for 0 / 7 / 100.
Verify: LeoKit `--filter LeoChatUnreadCountsTests`, then the full LeoKit suite. Commit.

## Step 2: Pane model reports successful reads
Files: `macos/Sources/Features/Leo/Chat/LeoChatPaneModel.swift`. Add an init param
`onRead: @escaping @MainActor (LeoAgentID) -> Void = { _ in }`. In `markRead` (:190-194), replace `try?` with
do/catch and call `onRead(agent)` only on success. Add `func marksRead(_ agent: LeoAgentID) -> Bool`
(isOnScreen && self.agent == agent && timeline.taskFilter == nil).
`macos/Tests/Leo/LeoChatTestSupport.swift`: give `FakeChatClient` a `failReads(_:)`, `setThreads(_:)` / `failThreads`,
and a threads-request counter with a waiter (the same pattern as `waitForPageRequests`).
Failing tests first (`LeoChatPaneModelTests.swift`): a successful markRead fires onRead(agent); a failing one doesn't;
a filtered thread neither reads nor fires; marksRead is true only on screen, for the shown agent, with no filter.
Verify: `leo-runtests.sh unread-2`. Commit.

## Step 3: `LeoChatUnreadStore` (Mac, observable wrapper)
New `macos/Sources/Features/Leo/Chat/LeoChatUnreadStore.swift`:
`@MainActor final class LeoChatUnreadStore: ObservableObject { @Published private(set) var counts: LeoChatUnreadCounts;
 init(client: any LeoChatClient, host: LeoHostID); updateClient(_:host:);
 receive(_ d: LeoChatFeedDelivery, isOnScreen: (LeoAgentID) -> Bool); clear(_:); count(for:) -> Int }`.
- `.event` from the bound host → `counts.receiving`.
- `.resync` from the bound host → starts a seed task (`client.threads()` → `seeding`). The task is token-guarded and
  replaces any earlier one. A result is dropped if the client or host changed meanwhile. A failed fetch keeps the current counts.
- The seed runs in its own task so a slow `threads()` never stalls the ordered chat relay.
Failing tests first, in new `macos/Tests/Leo/LeoChatUnreadStoreTests.swift`: resync fetches threads and seeds;
a resync or event from another host is ignored; a seed that lands after `updateClient` is dropped; a failed seed keeps counts.
Verify: `leo-runtests.sh unread-3`. Commit.

## Step 4: Auto-open decision
New `macos/Sources/Features/Leo/Chat/LeoChatAutoOpen.swift` with two pure functions:
`static func agent(asking: LeoChatFeedDelivery) -> LeoAgentID?` returns a value only for `.event(.message(m))` where
`m.isFromAgent && m.isOpen`. It is nil for `.updated` and `.resync`. History pages never pass through the relay.
`static func shouldOpen(_ agent:, shown: LeoAgentID?, layout: LeoChatLayout) -> Bool` returns `shown == agent && layout == .terminal`.
`LeoWindowSession.swift`: add `var shownAgent: LeoAgentID?` (`terminals.selection == nil ? selectedAgent() : nil`), have
`currentChatLayout` (:204) use it, and add `func openChatIfAsked(by agent:)`, which calls `choose(.chat, for:)` when
`shouldOpen` holds. Focus then follows the existing `choose` → `requestChatFocus` rules. It never activates the app
and never changes the selection.
Failing tests first, in new `macos/Tests/Leo/LeoChatAutoOpenTests.swift`:
- an open ask → chat; an open permission → chat
- no switch for: text, file, voice, task or system; an answered or expired ask; `.updated`; `.resync`; a user-direction
  message; another agent; a plain shell row selected in that window; a window already in `.chatReplacingTerminal` or `.sideBySide`
- two sessions: only the one showing the agent on Terminal switches. Build these with `LeoWindowSession(defaults:)` and a stubbed `selectedAgent`.
Verify: `leo-runtests.sh unread-4`. Commit.

## Step 5: Runtime wiring (glue; TDD exception: wiring, covered by Step 7)
`macos/Sources/Features/Leo/LeoRuntime.swift`:
- Add `let unread: LeoChatUnreadStore`, built from `localChatClient` before `chat` (:278).
- Build `chat` with `onRead: { [weak unread] in unread?.clear($0) }`.
- The relay sink (:283) runs in this order: `unread.receive(d, isOnScreen: chat.marksRead)` →
  `if let a = LeoChatAutoOpen.agent(asking: d) { registry.sessions.forEach { $0.openChatIfAsked(by: a) } }` → `await chat.handle(d)`.
- In `applyConnected` (:641), call `unread.updateClient(chatClient, host:)` next to `chat.updateClient`. The hello that
  follows triggers the seed (`LeoChatFeedSignal` maps hello/gap/snapshot → `.resync`).
- Counts stay in their own store, not in `LeoSidebarSnapshot`, so attention and unread remain independent.
Verify: `leo-runtests.sh unread-5` (whole suite green). Commit.

## Step 6: Badges (UI styling; TDD-exempt)
- New `macos/Sources/Features/Leo/Chat/LeoUnreadCountBadge.swift`, a SwiftUI capsule:
  - text from `LeoChatUnreadCounts.badgeText`; renders nothing when that is nil
  - `.caption2.weight(.semibold).monospacedDigit()`, horizontal padding 5, min 16×16
  - normally an accent fill with white text; on a selected (accent-highlighted) row, a white fill with accent text
  - `.accessibilityLabel("\(n) unread")`
- Chat segment: `LeoAgentControlBarHost` (`LeoAgentControlBar.swift:126-171`) gets `@ObservedObject var unread: LeoChatUnreadStore`.
  The count is `layout.showsChat ? 0 : unread.count(for: row.id)`. Both `LeoAgentViewSwitch` sites (the `.chatToggleOnly`
  site and `LeoAgentControlBar`:46) get `.overlay(alignment: .topTrailing) { badge.offset(x: 6, y: -6).allowsHitTesting(false) }`.
  NSSegmentedControl can't badge, so the capsule is a SwiftUI overlay that leaves clicks to the control.
  `macos/Sources/Features/Terminal/TerminalView.swift:148` passes `runtime.unread`.
- Sidebar: thread `unread` through `LeoSidebarSplit.swift:178-221` (and its construction site), then `LeoSidebarView.swift:81-108`
  (`@ObservedObject`), then `:374` `LeoAgentRowView(unreadCount:)`, then `LeoAgentRowContent(unreadCount: Int = 0)`. Render the
  badge at the end of `nameLine`, after `trailing(...)` (:42). The leading attention symbol is unchanged and the Dock count is untouched.
Verify: `leo-runtests.sh unread-6` (build and swiftlint clean). Commit.

## Step 7: Debug-app screenshot verification
Follow `.autopilot/verify.md` (isolated launch, Peekaboo with `--bridge-socket` and `--capture-engine cg`, target the
bundle id `studio.blackpaw.leo.macos.debug`).
1. Create `autopilot-scratch` with `leo`. Filter the sidebar to it (Agents ▸ Find Agent…), select it, and show Terminal.
2. Prompt the scratch agent through the daemon, never through the debug app's keyboard, to call `leo_chat_post` twice.
   Shot A shows the row capsule "2" and the Chat-segment capsule "2" on a selected row.
3. File ▸ New Terminal (selects a shell row). Shot B shows the unselected scratch row's capsule. Repeat shots A and B in dark mode.
4. Reselect scratch and click the Chat segment. Shot C shows both badges gone; `threads()` reports unread 0.
5. Switch back to Terminal and make another app frontmost. Have scratch call `leo_chat_ask`. Shot D shows the window has
   switched to Chat by itself and the debug app is still not frontmost. The same check with chat already visible must show no change.
Never press Return. Afterwards, quit via `pkill -f` on the debug binary path and delete `autopilot-scratch`.
Return the PNG paths for the orchestrator to post.

## Accepted risks
- Task filter: a filtered pane doesn't mark read, so it doesn't suppress either; counts follow the daemon.
- Seed race: a seed overwrites. A message stored after the daemon answers `threads()` but before the answer arrives is
  missing from the count until the next resync or read. This is milliseconds locally and longer over an SSH tunnel.
- Other hosts: only the selected host's counts are live. Switching hosts re-seeds on the next hello.
- `99+` is covered by the LeoKit test only.
- Auto-open moves focus to the composer, as `choose` already does. It fires only when the terminal is replaced (`.terminal`
  layout → chat), never in side-by-side, so the terminal is never left visible while its keystrokes go to the composer.
