import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Unread counts on the Mac: seeded from the daemon on every resync, bumped
/// by live agent messages, cleared by a read, and bound to one host.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoChatUnreadStoreTests {
    private static let alpha = LeoAgentID(host: .local, name: "alpha")
    private static let beta = LeoAgentID(host: .local, name: "beta")
    private static let remote = LeoHostID.remote("box")

    private let client = FakeChatClient()

    private func make() -> LeoChatUnreadStore { LeoChatUnreadStore(client: client, host: .local) }

    private func resync(_ store: LeoChatUnreadStore, host: LeoHostID = .local) async {
        store.receive(LeoChatFeedDelivery(host: host, signal: .resync), isOnScreen: { _ in false })
        await store.settled()
    }

    private func event(
        _ store: LeoChatUnreadStore, _ message: LeoChatMessage, host: LeoHostID = .local, isOnScreen: Bool = false
    ) {
        store.receive(LeoChatFeedDelivery(host: host, signal: .event(.message(message))), isOnScreen: { _ in isOnScreen })
    }

    @Test func aResyncFetchesThreadsAndSeedsTheCounts() async {
        await client.setThreads([LeoChatThread(agent: "alpha", unread: 3), LeoChatThread(agent: "beta", unread: 1)])
        let store = make()
        await resync(store)
        #expect(store.count(for: Self.alpha) == 3)
        #expect(store.count(for: Self.beta) == 1)
    }

    @Test func aLiveAgentMessageAddsToAnyAgentOnTheHost() async {
        let store = make()
        event(store, chatMessage("a", agent: "alpha", at: 1))
        event(store, chatMessage("b", agent: "beta", at: 2))
        event(store, chatMessage("c", agent: "beta", direction: .inbound, at: 3))
        #expect(store.count(for: Self.alpha) == 1)
        #expect(store.count(for: Self.beta) == 1)
    }

    @Test func anOnScreenAgentMessageDoesNotCount() {
        let store = make()
        store.receive(
            LeoChatFeedDelivery(host: .local, signal: .event(.message(chatMessage("a", agent: "alpha", at: 1)))),
            isOnScreen: { $0 == Self.alpha }
        )
        #expect(store.count(for: Self.alpha) == 0)
    }

    @Test func clearingZeroesTheAgent() async {
        await client.setThreads([LeoChatThread(agent: "alpha", unread: 3)])
        let store = make()
        await resync(store)
        store.clear(Self.alpha)
        #expect(store.count(for: Self.alpha) == 0)
    }

    @Test func aResyncReplacesLiveCounts() async {
        let store = make()
        event(store, chatMessage("a", agent: "alpha", at: 1))
        event(store, chatMessage("b", agent: "alpha", at: 2))
        await client.setThreads([LeoChatThread(agent: "alpha", unread: 1)])
        await resync(store)
        #expect(store.count(for: Self.alpha) == 1)
    }

    @Test func anotherHostsSignalsAreIgnored() async {
        let store = make()
        event(store, chatMessage("a", agent: "alpha", at: 1), host: Self.remote)
        await resync(store, host: Self.remote)
        #expect(store.count(for: Self.alpha) == 0)
        #expect(await client.threadRequestCount == 0)
    }

    @Test func aSeedThatLandsAfterTheClientChangedIsDropped() async {
        await client.setThreads([LeoChatThread(agent: "alpha", unread: 3)])
        await client.holdThreads()
        let store = make()
        store.receive(LeoChatFeedDelivery(host: .local, signal: .resync), isOnScreen: { _ in false })
        await client.waitForThreadRequests(1)
        store.updateClient(FakeChatClient(), host: Self.remote)
        await client.releaseThreads()
        await store.settled()
        #expect(store.count(for: Self.alpha) == 0)
    }

    @Test func aFailedSeedKeepsTheCurrentCounts() async {
        await client.setThreads([LeoChatThread(agent: "alpha", unread: 3)])
        let store = make()
        await resync(store)
        await client.failThreads("offline")
        await resync(store)
        #expect(store.count(for: Self.alpha) == 3)
    }
}
