import Foundation
import Testing

@testable import Ghostty

/// Background-agent notifications: opt-in via Agents ▸ Agent Notifications…,
/// `.alert` requested only on explicit enable, one notification per
/// (host, agent, revision), and only for transitions the reducer marked.
@MainActor struct LeoAttentionControllerTests {
    private static let alpha = LeoAgentRow.ID(host: .remote("mars"), name: "alpha")
    private let host = CurrentHost()

    @Test func notificationContentNamesAgentAndHostWithoutTerminalText() throws {
        let finished = try #require(LeoAttentionNotification(transition(.finished, revision: 3)))
        #expect(finished.title == "alpha · mars")
        #expect(finished.body == "Finished")
        #expect(finished.identifier == "studio.blackpaw.leo.attention.remote.mars.alpha.-.0.3")
        let scoped = try #require(LeoAttentionNotification(transition(.finished, revision: 3, bootID: "b1", incarnation: 2)))
        #expect(scoped.identifier == "studio.blackpaw.leo.attention.remote.mars.alpha.b1.2.3")

        let local = LeoAgentRow.ID(host: .local, name: "beta")
        let input = try #require(LeoAttentionNotification(transition(.needsInput, revision: 1, id: local)))
        #expect(input.title == "beta · localhost")
        #expect(input.body == "Needs your input")
    }

    @Test func onlyTransitionsMarkedShouldNotifyBecomeNotifications() {
        #expect(LeoAttentionNotification(transition(.finished, revision: 1, notify: false)) == nil)
        #expect(LeoAttentionNotification(transition(.errored, revision: 1, notify: true)) == nil)
    }

    @Test func userInfoRoundTripsTheAgent() throws {
        let notification = try #require(LeoAttentionNotification(transition(.finished, revision: 3)))
        #expect(LeoAttentionNotification.agent(fromUserInfo: notification.userInfo) == Self.alpha)
        let local = try #require(LeoAttentionNotification(transition(.finished, revision: 3, id: .init(host: .local, name: "b"))))
        #expect(LeoAttentionNotification.agent(fromUserInfo: local.userInfo) == .init(host: .local, name: "b"))
        #expect(LeoAttentionNotification.agent(fromUserInfo: ["surface": "x"]) == nil)
    }

    @Test func disabledByDefaultAndPostsNothing() async {
        let (controller, center, _) = makeController()

        await controller.handle([transition(.finished, revision: 1)])

        #expect(!controller.isEnabled)
        #expect(center.posted.isEmpty)
        #expect(center.authorizationRequests == 0)
    }

    @Test func enablingRequestsAlertAuthorizationThenPostsLiveTransitionsOnce() async {
        let (controller, center, _) = makeController()

        await controller.enable()
        await controller.handle([transition(.finished, revision: 1), transition(.working, revision: 1, notify: false)])
        await controller.handle([transition(.finished, revision: 1)])
        await controller.handle([transition(.needsInput, revision: 2)])

        #expect(center.authorizationRequests == 1)
        #expect(controller.isEnabled)
        #expect(center.posted.map(\.body) == ["Finished", "Needs your input"])
    }

    @Test func daemonRestartPostsRevisionsThatRepeatPreRestartOnes() async {
        let (controller, center, _) = makeController()
        await controller.enable()

        await controller.handle([transition(.finished, revision: 1, bootID: "b1")])
        await controller.handle([transition(.finished, revision: 1, bootID: "b2")])

        #expect(center.posted.count == 2)
    }

    @Test func resetAgentPostsRevisionsThatStartOver() async {
        let (controller, center, _) = makeController()
        await controller.enable()

        await controller.handle([transition(.finished, revision: 5, bootID: "b1")])
        await controller.handle([transition(.needsInput, revision: 1, bootID: "b1", incarnation: 1)])
        await controller.handle([transition(.needsInput, revision: 1, bootID: "b1", incarnation: 1)])

        #expect(center.posted.map(\.body) == ["Finished", "Needs your input"])
    }

    @Test func remembersOnlyTheLatestPostPerAgentOnTheCurrentHost() async {
        let (controller, _, _) = makeController()
        await controller.enable()

        for revision in 1...50 { await controller.handle([transition(.finished, revision: revision)]) }
        #expect(controller.rememberedPostCount == 1)

        host.current = .local
        await controller.handle([transition(.finished, revision: 1, id: .init(host: .local, name: "beta"))])
        #expect(controller.rememberedPostCount == 1, "a host switch prunes the old host's entries")
    }

    @Test func aLateBatchFromThePreviousHostIsDropped() async {
        let (controller, center, _) = makeController()
        await controller.enable()
        host.current = .local
        let beta = LeoAgentRow.ID(host: .local, name: "beta")
        await controller.handle([transition(.finished, revision: 3, id: beta)])

        await controller.handle([transition(.finished, revision: 1)])
        await controller.handle([transition(.finished, revision: 3, id: beta)])

        #expect(center.posted.map(\.title) == ["beta · localhost"], "mars' batch posts nothing and keeps beta's record")
    }

    @Test func deniedAuthorizationStaysOffAndShowsInstructionsOnce() async {
        let (controller, center, instructions) = makeController(granted: false)

        await controller.enable()
        await controller.enable()
        await controller.handle([transition(.finished, revision: 1)])

        #expect(!controller.isEnabled)
        #expect(instructions.count == 1)
        #expect(center.posted.isEmpty)
    }

    @Test func enabledStatePersistsAndCanBeTurnedOff() async {
        let defaults = freshDefaults()
        let (controller, _, _) = makeController(defaults: defaults)
        await controller.enable()
        let (reloaded, center, _) = makeController(defaults: defaults)
        #expect(reloaded.isEnabled)

        reloaded.disable()
        await reloaded.handle([transition(.finished, revision: 1)])

        #expect(!reloaded.isEnabled)
        #expect(center.posted.isEmpty)
        #expect(!controller.isEnabled, "reads through to defaults")
    }

    private func transition(
        _ state: LeoAttentionState, revision: Int, notify: Bool = true, id: LeoAgentRow.ID = alpha,
        bootID: String? = nil, incarnation: Int = 0
    ) -> LeoAttentionTransition {
        LeoAttentionTransition(
            id: id, from: .working, to: state, revision: revision, shouldNotify: notify, bootID: bootID, incarnation: incarnation
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "LeoAttentionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeController(
        granted: Bool = true, defaults: UserDefaults? = nil
    ) -> (LeoAttentionController, FakeNotificationCenter, InstructionsRecorder) {
        let center = FakeNotificationCenter(granted: granted)
        let instructions = InstructionsRecorder()
        let controller = LeoAttentionController(
            center: center, defaults: defaults ?? freshDefaults(), currentHost: { [host] in host.current },
            showDeniedInstructions: { instructions.count += 1 }
        )
        return (controller, center, instructions)
    }
}

@MainActor private final class FakeNotificationCenter: LeoNotificationPosting {
    let granted: Bool
    private(set) var authorizationRequests = 0
    private(set) var posted: [LeoAttentionNotification] = []
    init(granted: Bool) { self.granted = granted }
    func requestAlertAuthorization() async -> Bool {
        authorizationRequests += 1
        return granted
    }
    func post(_ notification: LeoAttentionNotification) async { posted.append(notification) }
}

@MainActor private final class CurrentHost {
    var current: LeoHostID? = .remote("mars")
}

@MainActor private final class InstructionsRecorder {
    var count = 0
}
