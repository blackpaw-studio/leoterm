import AppKit
import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// `LeoMachineRegistry` connects every machine at once. Every remote here
/// runs a scripted `LeoFakeTunnel`, and backoff sleeps go through a
/// `LeoManualSleeper`, so nothing waits on the wall clock.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct LeoMachineRegistryTests {
    private typealias Support = LeoMachineRegistryTestSupport

    // MARK: - Listing

    /// Settings lists machines in the store's order (by name).
    @Test func thisMacComesFirstThenEveryRemoteInSettingsOrder() throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("zeta"), Support.host("alpha", enabled: false), Support.host("mid")], to: defaults)

        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)

        #expect(registry.machines == [.local, .remote("alpha"), .remote("mid"), .remote("zeta")])
        #expect(registry.configuration(for: .remote("mid")) == Support.host("mid"))
        #expect(registry.configuration(for: .local) == nil)
        #expect(registry.status(for: .remote("alpha")) == .disabled)
        #expect(registry.status(for: .remote("gone")) == nil)
    }

    /// The spawn sheet's picker reads this, so a machine that connects, fails
    /// or is disabled changes its row without anyone asking the registry.
    @Test func machineStatusesPublishEveryMachineAsItsStatusChanges() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("off", enabled: false)], to: defaults)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)
        var latest: [LeoHostID: LeoMachineStatus] = [:]
        let subscription = registry.machineStatuses.sink { latest = $0 }
        defer { subscription.cancel() }

        #expect(latest == [.local: .connecting, .remote("a"): .connecting, .remote("off"): .disabled])

        registry.start(flavor: .socketEvents)

        try await until("a never reported connected") { @MainActor in latest[.remote("a")] == .connected }
        #expect(latest[.local] == .connected)
        #expect(latest[.remote("off")] == .disabled)
        registry.shutdown()
    }

    @Test func startConnectsThisMacAndEveryEnabledRemote() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)

        registry.start(flavor: .socketEvents)

        try await until("every machine never connected") { @MainActor in
            registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected
        }
        #expect(registry.status(for: .local) == .connected)
        #expect(registry.connectionState(for: .local) == .connected(socketPath: LeoMachineTunnelTestSupport.localSocketPath))
        #expect(registry.flavor == .socketEvents)
        registry.shutdown()
    }

    // MARK: - Isolation

    @Test func aMachineWhoseSSHHangsNeverHoldsUpAnother() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("b", remoteSocketPath: "~/.leo/state/leo.sock"), Support.host("a")], to: defaults)
        let runner = LeoHangingHomeRunner(hangingTarget: "evan@b")
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, runner: runner)

        registry.start(flavor: .socketEvents)

        try await until("b's ssh never ran") { await runner.hungCalls == 1 }
        try await until("a never connected while b hung") { @MainActor in registry.status(for: .remote("a")) == .connected }
        #expect(registry.status(for: .remote("b")) == .connecting)
        #expect(tunnels.tunnels("evan@b").isEmpty)
        registry.shutdown()
        await runner.release()
    }

    @Test func aTunnelThatDiesFailsOnlyItsOwnMachine() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let published = LeoLockedLog<LeoHostID>()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, connectionTarget: { host, _, _ in published.append(host) })
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }
        let aGeneration = registry.generation(for: .remote("a"))
        let publishedBefore = published.values.count

        tunnels.tunnels("evan@b").first?.exit(stderr: "Connection reset by peer")

        try await until("b never failed") { @MainActor in registry.status(for: .remote("b")) == .failed("Connection reset by peer") }
        #expect(registry.status(for: .remote("a")) == .connected)
        #expect(registry.generation(for: .remote("a")) == aGeneration)
        #expect(tunnels.tunnels("evan@a").map(\.terminationCount) == [0])
        #expect(published.values.dropFirst(publishedBefore).allSatisfy { $0 == .remote("b") })
        registry.shutdown()
    }

    // MARK: - Settings edits

    @Test func removingAMachineTearsDownThatMachineOnly() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }
        let aGeneration = registry.generation(for: .remote("a"))
        let bGeneration = registry.generation(for: .remote("b"))

        try Support.save([Support.host("a")], to: defaults)
        registry.reload()

        try await until("b was never torn down") { tunnels.tunnels("evan@b").first?.hasExited == true }
        #expect(tunnels.tunnels("evan@b").map(\.terminationCount) == [1])
        #expect(tunnels.tunnels("evan@a").map(\.terminationCount) == [0])
        #expect(registry.machines == [.local, .remote("a")])
        #expect(registry.status(for: .remote("b")) == nil)
        #expect(registry.status(for: .remote("a")) == .connected)
        #expect(registry.generation(for: .remote("a")) == aGeneration)
        #expect(registry.generation(for: .remote("b")) > bGeneration, "work started for b before it was removed must read as stale")
        registry.shutdown()
    }

    @Test func disablingAMachineTearsItDownAndKeepsItListed() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }

        try Support.save([Support.host("a"), Support.host("b", enabled: false)], to: defaults)
        registry.reload()

        try await until("b was never torn down") { tunnels.tunnels("evan@b").first?.hasExited == true }
        #expect(registry.machines == [.local, .remote("a"), .remote("b")])
        #expect(registry.status(for: .remote("b")) == .disabled)
        #expect(tunnels.tunnels("evan@a").map(\.terminationCount) == [0])
        registry.shutdown()
    }

    @Test func aDisabledMachineIsNeverConnected() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("off", enabled: false, remoteSocketPath: "~/.leo/state/leo.sock")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let runner = LeoFakeHomeRunner(stdout: "/home/evan")
        let center = NotificationCenter()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, runner: runner, activationCenter: center)

        registry.start(flavor: .socketEvents)
        registry.reconnect(.remote("off"))
        registry.reconnectUnavailable()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        registry.reload()

        try await until { @MainActor in registry.status(for: .remote("a")) == .connected }
        #expect(registry.status(for: .remote("off")) == .disabled)
        #expect(registry.connectionState(for: .remote("off")) == nil)
        #expect(tunnels.tunnels("evan@off").isEmpty)
        #expect(await runner.calls.isEmpty)
        registry.shutdown()
    }

    @Test func editingAMachineReconnectsThatMachineOnly() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }
        let aGeneration = registry.generation(for: .remote("a"))

        registry.reload()
        #expect(tunnels.all.count == 2, "a reload with nothing changed must leave every connection alone")

        let edited = LeoHostConfiguration(name: "b", sshTarget: "evan@b-new", remoteSocketPath: "/remote/leo.sock")
        try Support.save([Support.host("a"), edited], to: defaults)
        registry.reload()

        try await until("b never reconnected with its new settings") { @MainActor in
            registry.status(for: .remote("b")) == .connected && tunnels.tunnels("evan@b-new").count == 1
        }
        #expect(tunnels.tunnels("evan@b").map(\.terminationCount) == [1])
        #expect(tunnels.tunnels("evan@a").map(\.terminationCount) == [0])
        #expect(registry.generation(for: .remote("a")) == aGeneration)
        #expect(registry.configuration(for: .remote("b")) == edited)
        registry.shutdown()
    }

    /// An edit or a rename (both keep the id, which names the machine's
    /// sockets) replaces the machine's connection, but like any reconnect
    /// its new tunnel waits until the old one is gone: never two ssh
    /// children on one socket path.
    @Test(arguments: LeoMachineRegistryTestSupport.replacementsOfB)
    func aReplacedMachineLaunchesOnlyAfterItsOldTunnelIsGone(_ replacement: LeoHostConfiguration) async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let release = DispatchSemaphore(value: 0)
        tunnels.onTeardown("evan@b") { release.wait() }
        let aliveAtLaunch = LeoLockedLog<Int>()
        tunnels.onMake { made, earlier in
            aliveAtLaunch.append(earlier.filter { $0.launch.localSocketPath == made.launch.localSocketPath && !$0.hasExited }.count)
        }
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("b")) == .connected }
        let old = try #require(tunnels.tunnels("evan@b").first)

        // "c" is new in the same reload: it takes the path b's replacement
        // would without waiting, so once c's tunnel exists an unordered
        // replacement would have launched too.
        try Support.save([replacement, Support.host("c")], to: defaults)
        registry.reload()
        try await until("the old tunnel's teardown never started") { old.terminationCount == 1 }
        try await until("the control machine never launched") { tunnels.tunnels("evan@c").count == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(tunnels.tunnels(replacement.sshTarget).isEmpty, "the new tunnel launched while the old one was still alive")
        release.signal()

        try await until("the replacement never connected") { @MainActor in
            registry.status(for: .remote(replacement.name)) == .connected && tunnels.tunnels(replacement.sshTarget).count == 1
        }
        #expect(aliveAtLaunch.values == [0, 0, 0])
        registry.shutdown()
    }

    @Test func aMachineAddedInSettingsConnects() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected }

        try Support.save([Support.host("a"), Support.host("new")], to: defaults)
        registry.reload()

        try await until("the new machine never connected") { @MainActor in registry.status(for: .remote("new")) == .connected }
        #expect(tunnels.tunnels("evan@a").count == 1)
        registry.shutdown()
    }

    // MARK: - Retry

    @Test func failedMachinesRetryWithBackoffCappedAtSixtySeconds() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .fails("Connection refused"))
        let sleeper = LeoManualSleeper()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, sleeper: sleeper)

        registry.start(flavor: .socketEvents)
        for attempt in 1...8 {
            try await until("retry \(attempt) was never scheduled") { sleeper.pendingCount == 1 }
            sleeper.fireAll()
            try await until("retry \(attempt) never launched") { tunnels.tunnels("evan@b").count == attempt + 1 }
        }
        try await until { sleeper.pendingCount == 1 }

        let seconds: [Int64] = [1, 2, 4, 8, 16, 32, 60, 60, 60]
        #expect(sleeper.requested == seconds.map { .seconds($0) })
        #expect(registry.status(for: .remote("b")) == .failed("Connection refused"))
        registry.shutdown()
    }

    @Test func connectingStartsTheBackoffOver() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .fails("refused"), .fails("refused"), .ready, .fails("refused"))
        let sleeper = LeoManualSleeper()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, sleeper: sleeper)
        registry.start(flavor: .socketEvents)

        for _ in 1...2 {
            try await until { sleeper.pendingCount == 1 }
            sleeper.fireAll()
        }
        try await until("b never connected on its third attempt") { @MainActor in registry.status(for: .remote("b")) == .connected }
        tunnels.tunnels("evan@b").last?.exit(stderr: "Connection closed")
        try await until { sleeper.requested.count == 3 }

        #expect(sleeper.requested == [.seconds(1), .seconds(2), .seconds(1)])
        registry.shutdown()
    }

    @Test func activatingTheAppRetriesOnlyFailedMachines() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .fails("refused"))
        let sleeper = LeoManualSleeper()
        let center = NotificationCenter()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, sleeper: sleeper, activationCenter: center)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && sleeper.pendingCount == 1 }

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        try await until("b was never retried on activation") { tunnels.tunnels("evan@b").count == 2 }
        try await until { sleeper.requested.count == 2 }
        #expect(tunnels.tunnels("evan@a").count == 1)
        #expect(tunnels.tunnels("evan@a").map(\.terminationCount) == [0])
        #expect(sleeper.pendingCount == 1, "the retry activation replaced must be cancelled, not left to fire again")
        registry.shutdown()
    }

    @Test func reconnectUnavailableRetriesEveryMachineThatIsNotConnected() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b"), Support.host("c")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .fails("refused"))
        tunnels.script("evan@c", .hangs, .ready)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in
            registry.status(for: .remote("a")) == .connected
                && registry.status(for: .remote("b")) == .failed("refused")
                && tunnels.tunnels("evan@c").count == 1
        }

        registry.reconnectUnavailable()

        try await until("b and c were never retried") {
            tunnels.tunnels("evan@b").count == 2 && tunnels.tunnels("evan@c").count == 2
        }
        try await until { @MainActor in registry.status(for: .remote("c")) == .connected }
        #expect(tunnels.tunnels("evan@a").count == 1)
        registry.shutdown()
    }

    @Test func reconnectingThisMacStartsANewLocalGenerationOnly() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a")], to: defaults)
        let published = LeoLockedLog<(LeoHostID, Int, LeoHostConnectionState)>()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, connectionTarget: { published.append(($0, $1, $2)) })
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected }
        let localGeneration = registry.generation(for: .local)
        let aGeneration = registry.generation(for: .remote("a"))

        registry.reconnect(.local)

        #expect(registry.generation(for: .local) > localGeneration)
        #expect(registry.generation(for: .remote("a")) == aGeneration)
        let last = try #require(published.values.last)
        #expect(last.0 == .local)
        #expect(last.1 == registry.generation(for: .local))
        #expect(last.2 == .connected(socketPath: LeoMachineTunnelTestSupport.localSocketPath))
        registry.shutdown()
    }

    // MARK: - Shutdown

    @Test func shutdownWithAHungMachineReturnsAtTheBoundAndStillTearsTheOthersDown() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let release = DispatchSemaphore(value: 0)
        tunnels.onTeardown("evan@b") { release.wait() }
        let deadline = LeoTeardownDeadline()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels, waitForTeardown: { deadline.wait($0, $1) })
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }
        let a = try #require(tunnels.tunnels("evan@a").first)
        let b = try #require(tunnels.tunnels("evan@b").first)
        // The bound runs out while b is still stuck in its teardown.
        let expiry = Task.detached {
            try await until { a.hasExited && b.terminationCount == 1 }
            deadline.expire()
        }

        let finished = registry.shutdown()

        #expect(!finished)
        #expect(deadline.bounds == [.seconds(3)])
        #expect(a.hasExited)
        #expect(!b.hasExited)
        release.signal()
        try await expiry.value
    }

    @Test func shutdownTearsEveryTunnelDownInParallelUnderOneBound() async throws {
        let defaults = LeoInMemoryDefaults()
        let names = ["a", "b", "c"]
        try Support.save(names.map { Support.host($0) }, to: defaults)
        let tunnels = LeoFakeTunnels()
        // Each teardown waits for all three to be under way: run one at a
        // time, none of them ever finishes inside the bound.
        let rendezvous = LeoRendezvous(parties: names.count)
        names.forEach { tunnels.onTeardown("evan@\($0)") { rendezvous.arriveAndWait() } }
        let bounds = LeoLockedLog<Duration>()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels) { teardown, bound in
            bounds.append(bound)
            return LeoMachineRegistry.blockingWait(for: teardown, upTo: bound)
        }
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in names.allSatisfy { registry.status(for: .remote($0)) == .connected } }

        let finished = registry.shutdown()

        #expect(finished)
        #expect(bounds.values == [.seconds(3)])
        #expect(tunnels.all.allSatisfy { $0.hasExited })
    }

    @Test func nothingConnectsAfterShutdown() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected }

        registry.shutdown()
        try Support.save([Support.host("a"), Support.host("late")], to: defaults)
        registry.reload()
        registry.reconnect(.remote("a"))
        registry.reconnectUnavailable()

        #expect(registry.connectionState(for: .remote("late")) == nil)
        #expect(tunnels.all.count == 1)
    }

    // MARK: - Orphan store

    @Test func everyConnectionRecordsIntoTheOneOrphanStore() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)

        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected && registry.status(for: .remote("b")) == .connected }

        // A store opened fresh on the same defaults sees what was persisted:
        // stores of their own would each have overwritten the other's record.
        let persisted = LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: LeoMachineTunnelTestSupport.localSocketDirectory)
        #expect(Set(persisted.records().map(\.pid)) == Set(tunnels.all.map(\.fakePID)))
        #expect(registry.environment.orphanStore.records().count == 2)
        registry.shutdown()
    }
}

/// A test `TeardownWait`: returns when the teardown finishes or when the
/// test calls `expire()`, whichever is first, standing in for the bound.
final class LeoTeardownDeadline: @unchecked Sendable {
    private let wake = DispatchSemaphore(value: 0)
    private let requested = LeoLockedLog<Duration>()

    var bounds: [Duration] { requested.values }

    func wait(_ teardown: Task<Void, Never>, _ bound: Duration) -> Bool {
        requested.append(bound)
        let finished = LeoLockedLog<Bool>()
        Task.detached { [wake] in
            await teardown.value
            finished.append(true)
            wake.signal()
        }
        wake.wait()
        return !finished.values.isEmpty
    }

    func expire() { wake.signal() }
}

/// Holds every caller until `parties` have arrived (or 5s pass, so a broken
/// implementation fails instead of hanging).
final class LeoRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private let parties: Int
    private var arrived = 0
    private let allArrived = DispatchSemaphore(value: 0)

    init(parties: Int) { self.parties = parties }

    func arriveAndWait() {
        let isLast = lock.withLock { () -> Bool in
            arrived += 1
            return arrived == parties
        }
        if isLast { (0..<parties).forEach { _ in allArrived.signal() } }
        _ = allArrived.wait(timeout: .now() + 5)
    }
}
