import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The stats poller on an injected sleep (`LeoFiringClock`) and fake daemons:
/// nothing waits on the wall clock. Interval and request-timeout sleeps have
/// different lengths, so a test fires one without the other.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LeoMachineStatsPollerTests {
    private static let interval = UInt64(5) * 1_000_000_000
    private static let timeout = UInt64(3) * 1_000_000_000
    private static let remote = LeoHostID.remote("dionysus")

    @MainActor private final class Rig {
        let clock = LeoFiringClock()
        var daemons: [LeoHostID: StatsDaemon] = [:]
        var generations: [LeoHostID: Int] = [:]
        var features: [LeoHostID: LeoDaemonFeatures] = [:]
        var style = LeoStatsStyle.capsules
        var delivered: [(host: LeoHostID, stats: LeoMachineStats?)] = []
        private(set) var poller: LeoMachineStatsPoller!

        init() {
            poller = LeoMachineStatsPoller(dependencies: .init(
                daemon: { [unowned self] in daemons[$0] },
                generation: { [unowned self] in generations[$0, default: 1] },
                features: { [unowned self] in features[$0] ?? .none },
                style: { [unowned self] in style },
                deliver: { [unowned self] stats, host in delivered.append((host, stats)) },
                sleep: { [clock] nanoseconds in try await clock.sleep(nanoseconds) }
            ))
        }

        /// Connects `host` with a daemon that advertises `machine_stats`.
        @discardableResult
        func connect(_ host: LeoHostID, replies: [StatsDaemon.Reply] = [.stats(cpu: 10)], advertises: Bool = true) -> StatsDaemon {
            let daemon = StatsDaemon(replies: replies)
            daemons[host] = daemon
            features[host] = advertises ? LeoDaemonFeatures(["machine_stats"]) : .none
            return daemon
        }

        func goLive(_ hosts: [LeoHostID] = [.local]) {
            poller.setMachines(hosts)
            poller.setSidebarPollable(true)
            poller.setAppActive(true)
        }

        func lastStats(for host: LeoHostID) -> LeoMachineStats?? {
            delivered.last { $0.host == host }.map(\.stats)
        }
    }

    @Test func pollsOnceAtStartThenEveryFiveSeconds() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 1 }
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 2 }
        #expect(rig.delivered.count == 2)
    }

    @Test func doesNotPollWhileTheSidebarIsHidden() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.poller.setMachines([.local])
        rig.poller.setAppActive(true)
        rig.poller.setSidebarPollable(false)
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 0)
    }

    @Test func doesNotPollWhileTheAppIsInactive() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.poller.setMachines([.local])
        rig.poller.setSidebarPollable(true)
        rig.poller.setAppActive(false)
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 0)
    }

    @Test func stopsWhenTheSidebarIsHiddenAndResumesWithAnImmediatePoll() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.poller.setSidebarPollable(false)
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
        #expect(await daemon.calls == 1)
        rig.poller.setSidebarPollable(true)
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 2 }
    }

    @Test func stopsWhenTheAppResignsActive() async throws {
        let rig = Rig()
        rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.poller.setAppActive(false)
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
    }

    @Test func neverPollsAMachineWithoutTheStatsFlag() async throws {
        let rig = Rig()
        let old = rig.connect(.local, advertises: false)
        let current = rig.connect(Self.remote)
        rig.goLive([.local, Self.remote])
        #expect(rig.poller.pollingHosts == [Self.remote])
        try await eventually(sourceLocation: #_sourceLocation) { await current.calls == 1 }
        #expect(await old.calls == 0)
    }

    @Test func neverPollsADisconnectedMachine() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.daemons[.local] = nil
        rig.goLive()
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 0)
        #expect(rig.delivered.isEmpty)
    }

    @Test func doesNotPollWhenTheStyleIsOff() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.style = .off
        rig.goLive()
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 0)
    }

    @Test func turningTheStyleOffClearsMetersAndStopsPolling() async throws {
        let rig = Rig()
        rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) != nil }
        rig.style = .off
        rig.poller.reconcile()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
        #expect(rig.lastStats(for: .local) == .some(nil))
    }

    @Test func turningTheStyleBackOnPollsAgain() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.style = .off
        rig.goLive()
        #expect(rig.poller.pollingHosts.isEmpty)
        rig.style = .bars
        rig.poller.reconcile()
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 1 }
    }

    @Test func aHungMachineDoesNotDelayAnother() async throws {
        let rig = Rig()
        let hung = rig.connect(.local, replies: [.hang])
        let healthy = rig.connect(Self.remote)
        rig.goLive([.local, Self.remote])
        try await eventually(sourceLocation: #_sourceLocation) { await healthy.calls == 1 && rig.lastStats(for: Self.remote) != nil }
        #expect(await hung.calls == 1)
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { await healthy.calls == 2 }
    }

    @Test func aRequestThatNeverAnswersTimesOutAfterThreeSeconds() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local, replies: [.hang, .stats(cpu: 20)])
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.timeout).count == 1 }
        rig.clock.fire(Self.timeout)
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) != nil }
        #expect(await daemon.calls == 2)
    }

    @Test func threeMissesInARowClearTheMeters() async throws {
        let rig = Rig()
        rig.connect(.local, replies: [.stats(cpu: 10), .fail, .fail, .fail])
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) != nil }
        for _ in 0..<2 {
            try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
            rig.clock.fire(Self.interval)
        }
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        // Two misses so far: the last sample is still on screen.
        #expect(rig.lastStats(for: .local)??.cpu?.percent == 10)
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) == .some(nil) }
    }

    @Test func aCancellationWhileNotCancelledCountsAsAMissAndKeepsPolling() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local, replies: [.stats(cpu: 10), .cancelled, .stats(cpu: 40)])
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 2 }
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        #expect(rig.poller.pollingHosts == [.local])
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local)??.cpu?.percent == 40 }
    }

    @Test func aSuccessResetsTheMissCount() async throws {
        let rig = Rig()
        rig.connect(.local, replies: [.fail, .fail, .stats(cpu: 5), .fail, .fail, .stats(cpu: 6)])
        rig.goLive()
        for _ in 0..<5 {
            try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
            rig.clock.fire(Self.interval)
        }
        try await eventually(sourceLocation: #_sourceLocation) { rig.delivered.count == 2 }
        #expect(rig.delivered.allSatisfy { $0.stats != nil })
    }

    @Test(arguments: [
        LeoDaemonError.daemon(code: LeoMachineStats.unavailableCode, message: "no stats", matches: []),
        LeoDaemonError.daemon(code: "unauthorized", message: "no token", matches: []),
        LeoDaemonError.daemon(code: "forbidden", message: "api client", matches: []),
    ])
    func aRefusalClearsTheMetersAndStopsPollingUntilReconnect(error: LeoDaemonError) async throws {
        let rig = Rig()
        let daemon = rig.connect(.local, replies: [.stats(cpu: 10), .error(error), .stats(cpu: 30)])
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) == .some(nil) }
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
        // Visibility flips do not revive it; only a reconnect does.
        rig.poller.setSidebarPollable(false)
        rig.poller.setSidebarPollable(true)
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 2)
        rig.generations[.local] = 2
        rig.poller.reconcile()
        try await eventually(sourceLocation: #_sourceLocation) { await daemon.calls == 3 }
    }

    @Test func aReconnectDropsTheOldConnectionAndPollsTheNewOne() async throws {
        let rig = Rig()
        let old = rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { await old.calls == 1 }
        let replacement = StatsDaemon(replies: [.stats(cpu: 50)])
        rig.daemons[.local] = replacement
        rig.generations[.local] = 2
        rig.poller.reconcile()
        try await eventually(sourceLocation: #_sourceLocation) { await replacement.calls == 1 }
        #expect(rig.clock.pending(Self.interval).count == 1)
        #expect(await old.calls == 1)
    }

    @Test func aMachineLosingItsConnectionStopsAndClears() async throws {
        let rig = Rig()
        rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) != nil }
        rig.daemons[.local] = nil
        rig.poller.reconcile()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
        #expect(rig.lastStats(for: .local) == .some(nil))
    }

    @Test func aRemovedMachineIsCancelledAndCleared() async throws {
        let rig = Rig()
        rig.connect(.local)
        let remote = rig.connect(Self.remote)
        rig.goLive([.local, Self.remote])
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 2 }
        rig.poller.setMachines([.local])
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        #expect(rig.lastStats(for: Self.remote) == .some(nil))
        rig.clock.fire(Self.interval)
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        #expect(await remote.calls == 1)
    }

    @Test func stopCancelsEveryPollAndIgnoresLaterInputs() async throws {
        let rig = Rig()
        let daemon = rig.connect(.local)
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).count == 1 }
        rig.poller.stop()
        try await eventually(sourceLocation: #_sourceLocation) { rig.clock.pending(Self.interval).isEmpty }
        rig.poller.setSidebarPollable(false)
        rig.poller.setSidebarPollable(true)
        #expect(rig.poller.pollingHosts.isEmpty)
        #expect(await daemon.calls == 1)
    }

    @Test func aNullCPUPercentIsDeliveredAsASampleWithNoPercent() async throws {
        let rig = Rig()
        rig.connect(.local, replies: [.stats(cpu: nil)])
        rig.goLive()
        try await eventually(sourceLocation: #_sourceLocation) { rig.lastStats(for: .local) != nil }
        let cpu = rig.lastStats(for: .local)??.cpu
        #expect(cpu != nil)
        #expect(cpu?.percent == nil)
    }
}

/// Re-checks `condition` on the main actor every millisecond until it holds.
/// A condition still false at the deadline fails the test at the caller, so a
/// regression fails fast instead of hanging.
@MainActor private func eventually(
    deadline: Duration = .seconds(2),
    sourceLocation: SourceLocation,
    _ condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let limit = clock.now + deadline
    while !(await condition()) {
        guard clock.now < limit else {
            Issue.record("Condition was not satisfied within \(deadline)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// A daemon that answers `machineStats` from a script: the last reply repeats.
actor StatsDaemon: LeoDaemonClient {
    enum Reply: Sendable {
        case stats(cpu: Double?)
        case error(LeoDaemonError)
        case fail
        /// Throws `CancellationError` although nothing cancelled the request.
        case cancelled
        /// Never answers.
        case hang
    }

    private let replies: [Reply]
    private(set) var calls = 0

    init(replies: [Reply]) { self.replies = replies }

    func machineStats() async throws -> LeoMachineStats {
        let reply = replies[min(calls, replies.count - 1)]
        calls += 1
        switch reply {
        case .stats(let cpu):
            return LeoMachineStats(
                sampledAt: Date(timeIntervalSince1970: 0), cpu: .init(percent: cpu, cores: 8),
                memory: .init(usedBytes: 1, totalBytes: 2), disk: .init(path: "/", usedBytes: 1, totalBytes: 2)
            )
        case .error(let error): throw error
        case .fail: throw LeoDaemonError.transport("boom")
        case .cancelled: throw CancellationError()
        case .hang:
            try await Task.sleep(nanoseconds: .max)
            throw CancellationError()
        }
    }

    func listAgents() async throws -> [LeoAgent] { [] }
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
