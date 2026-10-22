import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// One feed per shown machine: only This Mac's forwards Leo Chat, and a
/// machine that leaves and comes back gets a fresh feed whose snapshots are
/// the only ones delivered for it.
@Suite(.timeLimit(.minutes(1)))
@MainActor struct LeoMachineFeedsTests {
    private static let work = LeoHostID.remote("work")

    @Test func onlyThisMacsFeedForwardsChat() async throws {
        let chats = LeoLockedLog<LeoChatFeedSignal>()
        let delivered = DeliveredSnapshots()
        let feeds = Self.feeds(
            localActivity: Self.activity(sending: Self.hello(features: [])), chats: chats, delivered: delivered
        )
        feeds.setMachines([.local, Self.work])
        feeds.start(pollable: false)

        feeds.updateConnection(host: Self.work, generation: 1, phase: .connected(
            daemon: LeoListingDaemon(names: []), activitySource: Self.activity(sending: Self.hello(features: ["attach_dispatch_placement"]))
        ))

        try await until { await delivered.last(for: Self.work)?.features.contains(.attachDispatchPlacement) == true }
        try await until { chats.values.count >= 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(chats.values == [.resync], "work's hello reached Chat")
    }

    @Test func aMachineThatLeavesAndComesBackOnlyEverDeliversItsNewFeedsSnapshots() async throws {
        let delivered = DeliveredSnapshots()
        let feeds = Self.feeds(delivered: delivered)
        feeds.setMachines([.local, Self.work])
        feeds.start(pollable: false)
        let old = try #require(feeds.feed(for: Self.work))

        feeds.setMachines([.local])
        feeds.setMachines([.local, Self.work])
        let fresh = try #require(feeds.feed(for: Self.work))
        #expect(fresh !== old)
        feeds.updateConnection(host: Self.work, generation: 1, phase: .connected(
            daemon: LeoListingDaemon(names: ["fresh"]), activitySource: Self.activity(sending: nil)
        ))
        try await until { await delivered.last(for: Self.work)?.rows.map(\.name) == ["fresh"] }

        // The retired feed still emits (a task it started before it was
        // stopped): its snapshot names a connection the machine no longer has.
        await old.updateConnection(host: Self.work, generation: 9, phase: .failed(message: "ghost"))
        await old.emit()
        await old.drainEmissions()

        #expect(await old.snapshot.connectivity == .failed(message: "ghost"))
        #expect(!delivered.all(for: Self.work).contains { $0.connectivity == .failed(message: "ghost") }, "the old feed's snapshot was delivered")
    }

    // MARK: - Helpers

    private static func feeds(
        localActivity: LeoSidebarActivitySource = activity(sending: nil),
        chats: LeoLockedLog<LeoChatFeedSignal> = LeoLockedLog(),
        delivered: DeliveredSnapshots
    ) -> LeoMachineFeeds {
        LeoMachineFeeds(dependencies: .init(
            localDaemon: LeoListingDaemon(names: []),
            localActivity: localActivity,
            onChat: { chats.append($0) },
            onSnapshot: { host, snapshot in delivered.record(snapshot, for: host) }
        ))
    }

    /// An activity stream that sends `event` (if any) and then stays open.
    nonisolated private static func activity(sending event: LeoObserveEvent?) -> LeoSidebarActivitySource {
        LeoSidebarActivitySource(
            events: {
                AsyncStream { continuation in
                    if let event { continuation.yield(event) }
                }
            },
            fetchState: { [] }
        )
    }

    nonisolated private static func hello(features: [String]) -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot", features: features)
    }
}

/// Every snapshot `LeoMachineFeeds` delivered, by machine.
@MainActor private final class DeliveredSnapshots {
    private var snapshots: [LeoHostID: [LeoSidebarSnapshot]] = [:]

    func record(_ snapshot: LeoSidebarSnapshot, for host: LeoHostID) { snapshots[host, default: []].append(snapshot) }
    func all(for host: LeoHostID) -> [LeoSidebarSnapshot] { snapshots[host] ?? [] }
    func last(for host: LeoHostID) -> LeoSidebarSnapshot? { snapshots[host]?.last }
}

/// Lists one running agent per name; every other call is unexpected.
struct LeoListingDaemon: LeoDaemonClient {
    let names: [String]

    func listAgents() async throws -> [LeoAgent] {
        names.map {
            LeoAgent(
                name: $0, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
                startedAt: "2026-10-21T00:00:00Z", restarts: nil, stoppedReason: nil, wakeOnMessage: nil
            )
        }
    }

    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
