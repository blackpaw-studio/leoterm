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
}
