import Darwin
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// `LeoMachineConnection` is one machine's connection. These are the old
/// single host selection's teardown races replayed as reconnects of the
/// same machine, on scripted `LeoFakeTunnel`s, so each boundary ("the old
/// tunnel is gone before the new one launches") is checked exactly.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct LeoMachineConnectionTests {
    private let configuration = LeoMachineRegistryTestSupport.host("work")

    /// The same-machine form of A→B→A: three connects in a row, the first
    /// still waiting on its health probe. No tunnel may launch while an
    /// earlier one is alive, and only the last generation publishes.
    @Test func rapidReconnectsNeverOverlapTwoTunnelsAndOnlyTheLastGenerationConnects() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .hangs, .ready)
        let aliveAtLaunch = LeoLockedLog<Int>()
        tunnels.onMake { _, earlier in aliveAtLaunch.append(earlier.filter { !$0.hasExited }.count) }
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)

        harness.connection.connect()
        try await until { tunnels.all.count == 1 }
        harness.connection.connect()
        harness.connection.connect()

        try await until("the last connect never connected") { @MainActor in
            LeoMachineRegistryTestSupport.isConnected(harness.connection.state)
        }
        #expect(aliveAtLaunch.values == [0, 0])
        #expect(tunnels.all.count == 2, "the superseded middle connect must never launch")
        let connected = harness.published.filter { LeoMachineRegistryTestSupport.isConnected($0.1) }
        #expect(connected.map(\.0) == [harness.connection.generation])
        #expect(harness.connection.generation == 3)
        await harness.connection.shutdown().value
    }

    /// A superseded tunnel's probe answers after the replacement connected:
    /// it must be torn down without publishing, and clearing its reap
    /// record must not drop the replacement's record at the same socket.
    @Test func aSupersededTunnelWhoseProbeAnswersLateNeverPublishesAndKeepsTheNewRecord() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .gated, .ready)
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        let store = harness.environment.orphanStore

        harness.connection.connect()
        try await until { store.records().count == 1 }
        harness.connection.connect()
        try await until { @MainActor in LeoMachineRegistryTestSupport.isConnected(harness.connection.state) }
        let stale = try #require(tunnels.all.first)
        let fresh = try #require(tunnels.all.last)

        stale.open()

        try await until("the stale tunnel was never torn down after its late answer") { stale.terminationCount == 2 }
        #expect(store.records().map(\.pid) == [fresh.fakePID])
        #expect(harness.published.filter { LeoMachineRegistryTestSupport.isConnected($0.1) }.count == 1)
        #expect(harness.connection.state == .connected(socketPath: harness.environment.tunnelSocketPath(for: configuration)))
        await harness.connection.shutdown().value
    }

    @Test func aTunnelThatDiesBeforeItIsReadyFailsWithItsHint() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .hangs)
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        harness.connection.connect()
        try await until { tunnels.all.count == 1 }

        tunnels.all.first?.exit(stderr: "Permission denied (publickey)")

        try await until { @MainActor in LeoMachineRegistryTestSupport.isFailed(harness.connection.state) }
        #expect(harness.connection.state == .failed(
            message: "Permission denied (publickey)",
            hint: "ssh needs a key or agent in BatchMode; try `ssh evan@work` in a terminal"
        ))
    }

    @Test func aTunnelThatDiesAfterConnectingFailsWithoutRelaunching() async throws {
        let tunnels = LeoFakeTunnels()
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        harness.connection.connect()
        try await until { @MainActor in LeoMachineRegistryTestSupport.isConnected(harness.connection.state) }
        let generation = harness.connection.generation

        tunnels.all.first?.exit(stderr: "Connection closed by remote host")

        try await until { @MainActor in LeoMachineRegistryTestSupport.isFailed(harness.connection.state) }
        #expect(harness.published.last?.0 == generation)
        for _ in 0..<20 { await Task.yield() }
        #expect(tunnels.all.count == 1, "a connection never relaunches on its own; the registry decides when to retry")
    }

    @Test func shutdownTearsTheTunnelDownAndRefusesLaterConnects() async throws {
        let tunnels = LeoFakeTunnels()
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        harness.connection.connect()
        try await until { @MainActor in LeoMachineRegistryTestSupport.isConnected(harness.connection.state) }
        let generation = harness.connection.generation

        await harness.connection.shutdown().value
        harness.connection.connect()

        #expect(tunnels.all.map(\.terminationCount) == [1])
        #expect(tunnels.all.count == 1)
        #expect(harness.connection.generation == generation)
    }

    @Test func shutdownWhileConnectingLeavesNoTunnelAndPublishesNothingMore() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .hangs)
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        harness.connection.connect()
        try await until { tunnels.all.count == 1 }
        let publishedBefore = harness.published.count

        await harness.connection.shutdown().value

        #expect(tunnels.all.first?.hasExited == true)
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.published.count == publishedBefore)
    }

    @Test func theOrphanRecordIsWrittenAtLaunchAndClearedOnExit() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .hangs)
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        let store = harness.environment.orphanStore
        harness.connection.connect()

        try await until { store.records().count == 1 }
        let tunnel = try #require(tunnels.all.first)
        #expect(harness.connection.state == .connecting)
        #expect(store.records() == [LeoTunnelOrphanRecord(
            pid: tunnel.fakePID, startTime: tunnel.startTime, socketPath: harness.environment.tunnelSocketPath(for: configuration)
        )])

        tunnel.exit()

        try await until("the record outlived its tunnel") { store.records().isEmpty }
    }

    @Test func clearingAfterAConfirmedShutdownDropsTheRecord() async throws {
        let tunnels = LeoFakeTunnels()
        let harness = Harness(target: .remote(configuration), tunnels: tunnels)
        let store = harness.environment.orphanStore
        harness.connection.connect()
        try await until { @MainActor in LeoMachineRegistryTestSupport.isConnected(harness.connection.state) }
        try await until { store.records().count == 1 }

        await harness.connection.shutdown().value
        harness.connection.clearOrphanRecord()

        #expect(store.records().isEmpty)
    }

    @Test func thisMacConnectsToTheLocalSocketAtOnce() {
        let tunnels = LeoFakeTunnels()
        let harness = Harness(target: .local, tunnels: tunnels)

        harness.connection.connect()

        #expect(harness.connection.state == .connected(socketPath: LeoMachineTunnelTestSupport.localSocketPath))
        #expect(harness.published.map(\.0) == [1])
        #expect(tunnels.all.isEmpty)
    }

    /// The production factory: a real `LeoTunnel` around `fake_ssh.py`,
    /// whose teardown runs off the cooperative pool.
    @Test func theRealTunnelLaunchesAndShutdownKillsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lmc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid").path
        let ssh = try Self.pidRecordingSSH(in: directory, pidFile: pidFile)
        let defaults = LeoInMemoryDefaults()
        let socketDirectory = LeoMachineTunnelTestSupport.localSocketDirectory
        let environment = LeoMachineConnectionEnvironment(
            orphanStore: LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: socketDirectory),
            runner: LeoFakeHomeRunner(stdout: "/home/evan"),
            sshExecutable: ssh,
            transport: LeoAlwaysHealthyTransport(),
            localSocketPath: LeoMachineTunnelTestSupport.localSocketPath,
            legacySocketDirectory: socketDirectory,
            controlSocketDirectory: socketDirectory
        )
        var generation = 0
        let connection = LeoMachineConnection(target: .remote(configuration), environment: environment, nextGeneration: {
            generation += 1
            return generation
        }, onState: { _, _ in })

        connection.connect()
        try await until { @MainActor in LeoMachineRegistryTestSupport.isConnected(connection.state) }
        let pid = try await LeoMachineTunnelTestSupport.awaitPID(pidFile)

        await connection.shutdown().value

        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    private static func pidRecordingSSH(in directory: URL, pidFile: String) throws -> URL {
        let script = directory.appendingPathComponent("ssh")
        let body = "#!/bin/sh\nFAKE_SSH_PID_FILE='\(pidFile)' exec '\(LeoTunnelTestSupport.fixtureURL().path)' \"$@\"\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

/// One connection on fake tunnels, recording what it publishes.
@MainActor private final class Harness {
    let environment: LeoMachineConnectionEnvironment
    let connection: LeoMachineConnection
    private let log: LeoLockedLog<(Int, LeoHostConnectionState)>

    var published: [(Int, LeoHostConnectionState)] { log.values }

    init(target: LeoMachineConnection.Target, tunnels: LeoFakeTunnels) {
        let environment = LeoMachineRegistryTestSupport.environment(defaults: LeoInMemoryDefaults(), tunnels: tunnels)
        let issued = LeoLockedLog<Int>()
        let log = LeoLockedLog<(Int, LeoHostConnectionState)>()
        self.environment = environment
        self.log = log
        connection = LeoMachineConnection(target: target, environment: environment, nextGeneration: {
            issued.append(issued.values.count + 1)
            return issued.values.count
        }, onState: { log.append(($0, $1)) })
    }
}
