// Smoke coverage of the real UIKit wiring: these pass without the B-347 fix too; the reducer tests in AppFeatureChatTests are the regression guards.
import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// B-347: an agent's message arriving while you view its chat never badges the
/// row or the Chats tab. Drives the real tab bar over a real store.
@MainActor
@Suite(.serialized)
struct ChatOnScreenTests {
    private static let daemon = PairedDaemon(
        id: "d-dionysus", name: "Dionysus", baseURL: URL(string: "http://10.0.2.10:8370")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )
    private static let zeus = AgentRef(daemonID: daemon.id, name: "zeus")

    private func withoutAnimations(_ body: () async throws -> Void) async rethrows {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        try await body()
    }

    private func rig() -> (store: StoreOf<AppFeature>, root: RootTabBarController, window: UIWindow) {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [Self.daemon])
        state.fleet.isActive = true
        state.fleet.sessions[0].connection = .connected
        state.fleet.sessions[0].agents = [Agent(name: "zeus", status: .running, template: "coding")]
        let store = Store(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.threads = { _ in [LeoChatThread(agent: "zeus")] }
            $0.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
            $0.chatClient.markRead = { _, _, _ in }
        }
        let root = RootTabBarController(store: store)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { preconditionFailure("The hosted test app has no window scene") }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return (store, root, window)
    }

    private func turnRunLoop() {
        RunLoop.main.run(mode: .default, before: Date())
    }

    private func pump() async {
        await Task.yield()
        turnRunLoop()
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await pump() }
    }

    @Test func anAgentMessageWhileYouViewItsChatBadgesNothing() async throws {
        try await withoutAnimations {
            let (store, root, window) = rig()
            defer { window.isHidden = true }
            await settle { store.chats.isActive && store.chats.threads[Self.daemon.id] != nil }

            // The user taps the row; the thread opens and appears.
            store.send(.chats(.rowTapped(Self.zeus)))
            await settle { store.chat?.isOnScreen == true }
            #expect(store.chat?.isOnScreen == true)

            store.send(.fleet(.eventReceived(Self.daemon.id, .chat(seq: 3, .message(LeoChatMessage(id: "01", agent: "zeus", direction: .outbound, kind: .text, text: "hi", ts: Date(timeIntervalSince1970: 2_000)))))))
            await settle { store.chats.threads[Self.daemon.id]?[id: "zeus"]?.lastMessage != nil }
            for _ in 0..<20 { await pump() }

            #expect(store.chats.unreadTotal == 0)
            #expect(root.tabs.first?.badgeValue == nil)
        }
    }

    @Test func returningToTheChatsTabClearsWhatArrivedWhileAway() async throws {
        try await withoutAnimations {
            let (store, root, window) = rig()
            defer { window.isHidden = true }
            await settle { store.chats.isActive && store.chats.threads[Self.daemon.id] != nil }
            store.send(.chats(.rowTapped(Self.zeus)))
            await settle { store.chat?.isOnScreen == true }

            store.send(.tabSelected(.agents))
            await settle { store.chat?.isOnScreen == false }
            #expect(store.chat?.isOnScreen == false)
            store.send(.fleet(.eventReceived(Self.daemon.id, .chat(seq: 3, .message(Self.message)))))
            await settle { root.tabs.first?.badgeValue == "1" }
            #expect(root.tabs.first?.badgeValue == "1")

            store.send(.tabSelected(.chats))
            await settle { store.chat?.isOnScreen == true && root.tabs.first?.badgeValue == nil }
            #expect(store.chats.unreadTotal == 0)
            #expect(root.tabs.first?.badgeValue == nil)
        }
    }

    private static let message = LeoChatMessage(id: "01", agent: "zeus", direction: .outbound, kind: .text, text: "hi", ts: Date(timeIntervalSince1970: 2_000))
}
