import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Finish notifications: opt-in, deduped by (agent, task, ended_at), and
/// suppressed while the user is watching that agent.
@MainActor struct LeoProgressNotifierTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let alpha = LeoAgentRow.ID(host: .local, name: "alpha")

    private static func finish(_ state: LeoAgentTask.State = .succeeded, id: String = "build", ended: TimeInterval = 60) -> LeoTaskFinish {
        LeoTaskFinish(agent: "alpha", task: LeoAgentTask(
            id: id, title: "Xcode build", state: state, startedAt: t0, endedAt: t0.addingTimeInterval(ended), revision: 2
        ))
    }

    private func make(enabled: Bool = true, watching: Bool = false) -> (LeoProgressNotifier, Center) {
        let center = Center()
        let notifier = LeoProgressNotifier(center: center, isEnabled: { enabled }, isWatching: { _ in watching })
        return (notifier, center)
    }

    @Test func postsDoneAndFailedWithTheTaskTitle() async {
        let (notifier, center) = make()
        await notifier.handle(host: .local, finishes: [Self.finish(.succeeded), Self.finish(.failed, id: "lint")])
        #expect(center.posted.map(\.body) == ["Done: Xcode build", "Failed: Xcode build"])
        #expect(center.posted.first?.title == "alpha · localhost")
        #expect(LeoAttentionNotification.agent(fromUserInfo: center.posted[0].userInfo) == Self.alpha)
    }

    @Test func silentUntilTheUserOptedIn() async {
        let (notifier, center) = make(enabled: false)
        await notifier.handle(host: .local, finishes: [Self.finish()])
        #expect(center.posted.isEmpty)
    }

    @Test func suppressedWhileWatchingThatAgent() async {
        let (notifier, center) = make(watching: true)
        await notifier.handle(host: .local, finishes: [Self.finish()])
        #expect(center.posted.isEmpty)
    }

    @Test func theSameFinishPostsOnceButANewRunPostsAgain() async {
        let (notifier, center) = make()
        await notifier.handle(host: .local, finishes: [Self.finish()])
        await notifier.handle(host: .local, finishes: [Self.finish()])
        #expect(center.posted.count == 1)
        await notifier.handle(host: .local, finishes: [Self.finish(ended: 600)])
        #expect(center.posted.count == 2)
        #expect(Set(center.posted.map(\.identifier)).count == 2)
    }

    @Test func aSuppressedFinishIsNotRememberedSoItCanStillNotifyLater() async {
        var watching = true
        let center = Center()
        let notifier = LeoProgressNotifier(center: center, isEnabled: { true }, isWatching: { _ in watching })
        await notifier.handle(host: .local, finishes: [Self.finish()])
        watching = false
        await notifier.handle(host: .local, finishes: [Self.finish()])
        #expect(center.posted.count == 1)
    }

    @Test func aBatchFromAMachineThatLeftIsDropped() async {
        let center = Center()
        let notifier = LeoProgressNotifier(center: center, isEnabled: { true }, isWatching: { _ in false }, isLive: { $0 == .local })
        await notifier.handle(host: .remote("mars"), finishes: [Self.finish()])
        #expect(center.posted.isEmpty)
    }

    @MainActor private final class Center: LeoNotificationPosting {
        private(set) var posted: [LeoAttentionNotification] = []
        func requestAlertAuthorization() async -> Bool { true }
        func post(_ notification: LeoAttentionNotification) async { posted.append(notification) }
    }
}
