import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// E3: `browser_handoff` shows a banner and posts a local notification;
/// Done and Decline settle the parked call.
@MainActor
struct LeoHandoffTests {
    private final class FakePoster: LeoNotificationPosting {
        private(set) var posted: [LeoAttentionNotification] = []
        func requestAlertAuthorization() async -> Bool { true }
        func post(_ notification: LeoAttentionNotification) async { posted.append(notification) }
    }

    private static let key = LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha")

    private let presence = FakePresence()
    private let poster = FakePoster()

    /// The agent calls `browser_handoff` and is left waiting.
    private func startHandoff(
        on source: FakePaneSource, id: String = "ctr_1", message: String = "Log in please"
    ) -> Task<LeoBrowserControl.HandoffOutcome?, Never> {
        let task = Task { await source.control.requestHandoff(requestID: id, message: message) }
        return task
    }

    @Test
    func handoffShowsBannerAndPostsNotification() async throws {
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster)
        let source = presence.open(Self.key)
        let model = LeoAgentBrowserPaneModel(source: source)

        let answer = startHandoff(on: source)
        await Task.yield()
        await notifier.posting?.value

        #expect(model.handoff == LeoAgentBrowserPaneModel.Handoff(requestID: "ctr_1", message: "Log in please"))
        #expect(model.pill.title == "You have control")
        let notification = try #require(poster.posted.first)
        #expect(poster.posted.count == 1)
        #expect(notification.title == "alpha · \(LeoHostID.remote("dionysus").displayName)")
        #expect(notification.body == "Log in please")
        #expect(LeoAttentionNotification.agent(fromUserInfo: notification.userInfo) == LeoAgentRow.ID(host: .remote("dionysus"), name: "alpha"))
        model.decline()
        _ = await answer.value
    }

    @Test
    func doneSettlesTheCallWithDoneAndGivesControlBack() async {
        let source = presence.open(Self.key)
        let model = LeoAgentBrowserPaneModel(source: source)
        let answer = startHandoff(on: source)
        await Task.yield()

        model.done()

        #expect(await answer.value == .done)
        #expect(model.handoff == nil)
        #expect(source.control.state == .agent)
    }

    @Test
    func declineSettlesTheCallWithDeclined() async {
        let source = presence.open(Self.key)
        let model = LeoAgentBrowserPaneModel(source: source)
        let answer = startHandoff(on: source)
        await Task.yield()

        model.decline()

        #expect(await answer.value == .declined)
        #expect(model.handoff == nil)
        #expect(source.control.state == .agent)
    }

    @Test
    func cancelledRequestRemovesTheBannerAndLeavesControlWithTheUser() async {
        let source = presence.open(Self.key)
        let model = LeoAgentBrowserPaneModel(source: source)
        let answer = startHandoff(on: source)
        await Task.yield()
        #expect(model.handoff != nil)

        answer.cancel()
        #expect(await answer.value == nil)

        #expect(model.handoff == nil)
        #expect(source.control.state == .user)
    }

    @Test
    func theSameRequestNotifiesOnce() async {
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster)
        let source = presence.open(Self.key)

        let first = startHandoff(on: source)
        await Task.yield()
        // Re-delivered after a reconnect: it joins the first call.
        let again = startHandoff(on: source)
        await Task.yield()
        await notifier.posting?.value

        #expect(poster.posted.count == 1)
        source.control.send(.done(requestID: "ctr_1"))
        _ = await (first.value, again.value)
    }

    @Test
    func aNewRequestNotifiesAgain() async {
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster)
        let source = presence.open(Self.key)

        let first = startHandoff(on: source, id: "ctr_1")
        await Task.yield()
        source.control.send(.done(requestID: "ctr_1"))
        _ = await first.value
        let second = startHandoff(on: source, id: "ctr_2", message: "Solve the captcha")
        await Task.yield()
        await notifier.posting?.value

        #expect(poster.posted.map(\.body) == ["Log in please", "Solve the captcha"])
        source.control.send(.done(requestID: "ctr_2"))
        _ = await second.value
    }

    @Test
    func watchesBrowsersThatExistedBeforeItStarted() async {
        let source = presence.open(Self.key)
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster)

        let answer = startHandoff(on: source)
        await Task.yield()
        await notifier.posting?.value

        #expect(poster.posted.count == 1)
        source.control.send(.done(requestID: "ctr_1"))
        _ = await answer.value
    }

    @Test
    func staysQuietWhenNotificationsAreOff() async {
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster, isEnabled: { false })
        let source = presence.open(Self.key)

        let answer = startHandoff(on: source)
        await Task.yield()
        await notifier.posting?.value

        #expect(poster.posted.isEmpty)
        source.control.send(.done(requestID: "ctr_1"))
        _ = await answer.value
    }

    @Test
    func stopsWatchingABrowserThatClosed() async {
        let notifier = LeoHandoffNotifier(presence: presence, poster: poster)
        let source = presence.open(Self.key)
        presence.remove(Self.key)

        let answer = startHandoff(on: source)
        await Task.yield()
        await notifier.posting?.value

        #expect(poster.posted.isEmpty)
        source.control.send(.done(requestID: "ctr_1"))
        _ = await answer.value
    }

    // MARK: - Banner layout

    /// The banner's height at `width` for `message`, laid out in a window.
    private func bannerHeight(_ message: String, width: CGFloat) -> CGFloat {
        let banner = LeoHandoffBanner()
        banner.show(LeoAgentBrowserPaneModel.Handoff(requestID: "r", message: message))
        let column = NSStackView(views: [banner])
        column.orientation = .vertical
        column.alignment = .width
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = column
        column.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        column.layoutSubtreeIfNeeded()
        return banner.fittingSize.height
    }

    @Test
    func aLongMessageWrapsToThreeLinesOnANarrowPane() {
        let short = bannerHeight("Log in", width: 420)
        let long = bannerHeight(String(repeating: "Log in to GitHub for me, then press Done. ", count: 3), width: 420)
        let veryLong = bannerHeight(String(repeating: "Log in to GitHub for me, then press Done. ", count: 30), width: 420)

        #expect(long >= short + 12, "the message wraps instead of truncating on one line")
        #expect(veryLong > long)
        #expect(veryLong <= short + 3 * 16, "three lines at most, then an ellipsis")
    }

    @Test
    func theWholeMessageIsInTheTooltip() {
        let banner = LeoHandoffBanner()
        let message = String(repeating: "Log in to GitHub. ", count: 20)

        banner.show(LeoAgentBrowserPaneModel.Handoff(requestID: "r", message: message))

        #expect(banner.toolTipForMessage == message)
    }
}
