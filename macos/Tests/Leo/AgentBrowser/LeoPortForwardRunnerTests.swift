import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Records every ssh invocation and answers with scripted results: one per
/// call in order, the last repeating.
actor RecordingForwardSSH: LeoProcessRunning {
    private(set) var calls: [[String]] = []
    private let results: [(status: Int32, stderr: String)]

    init(_ results: (status: Int32, stderr: String)...) {
        self.results = results.isEmpty ? [(0, "")] : results
    }

    func run(executable _: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        let result = results[min(calls.count, results.count - 1)]
        calls.append(arguments)
        return LeoProcessResult(stdout: Data(), stderr: Data(result.stderr.utf8), status: result.status)
    }
}

struct LeoPortForwardRunnerTests {
    private static let configuration = LeoHostConfiguration(name: "Build", sshTarget: "evan@build.example")
    private static let command = LeoSSHCommand(configuration: configuration)
    private static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    private func mux(_ ssh: RecordingForwardSSH, ipv6: Bool = true) -> LeoMuxForwardRunner {
        LeoMuxForwardRunner(
            command: Self.command, controlPath: "/tmp/cm-build", runner: ssh, sshExecutable: Self.ssh,
            prober: FakePortProber(ipv6Available: ipv6)
        )
    }

    private func argv(_ local: Int, _ op: LeoForwardOperation, _ address: LeoLoopbackAddress, remote: Int = 5173) throws -> [String] {
        try Self.command.forwardArguments(controlPath: "/tmp/cm-build", local: local, remotePort: remote, op: op, address: address)
    }

    @Test func openForwardsBothLoopbacksThroughTheControlMaster() async throws {
        let ssh = RecordingForwardSSH()
        try await mux(ssh).open(local: 5173, remotePort: 5173)
        #expect(await ssh.calls == [try argv(5173, .forward, .ipv4), try argv(5173, .forward, .ipv6)])
    }

    @Test func openIsIPv4OnlyWhenTheMachineHasNoIPv6Loopback() async throws {
        let ssh = RecordingForwardSSH()
        try await mux(ssh, ipv6: false).open(local: 5173, remotePort: 5173)
        #expect(await ssh.calls == [try argv(5173, .forward, .ipv4)])
    }

    @Test func status255MeansThePortIsBusy() async {
        let ssh = RecordingForwardSSH((255, "Port forwarding failed"))
        await #expect(throws: LeoPortForwardError.portBusy) {
            try await mux(ssh).open(local: 5173, remotePort: 5173)
        }
    }

    @Test func aBusyIPv6PortWithdrawsTheIPv4ForwardToo() async throws {
        let ssh = RecordingForwardSSH((0, ""), (255, "Port forwarding failed"), (0, ""))
        await #expect(throws: LeoPortForwardError.portBusy) {
            try await mux(ssh).open(local: 5173, remotePort: 5173)
        }
        #expect(await ssh.calls == [try argv(5173, .forward, .ipv4), try argv(5173, .forward, .ipv6), try argv(5173, .cancel, .ipv4)])
    }

    @Test func anIPv6ListenerThatCannotBindFallsBackToIPv4Only() async throws {
        let ssh = RecordingForwardSSH((0, ""), (255, "bind [::1]:5173: Cannot assign requested address"), (0, ""))
        let runner = mux(ssh)
        try await runner.open(local: 5173, remotePort: 5173)
        await runner.close(local: 5173, remotePort: 5173)
        #expect(await ssh.calls == [try argv(5173, .forward, .ipv4), try argv(5173, .forward, .ipv6), try argv(5173, .cancel, .ipv4)],
                "the v4 forward stays and is the only one cancelled")
    }

    @Test func otherFailuresCarryStderr() async {
        let ssh = RecordingForwardSSH((1, "mux_client_request_session: boom"))
        await #expect(throws: LeoPortForwardError.failed("mux_client_request_session: boom")) {
            try await mux(ssh).open(local: 5173, remotePort: 5173)
        }
    }

    @Test func closeCancelsEveryForwardOpenCreated() async throws {
        let ssh = RecordingForwardSSH()
        let runner = mux(ssh)
        try await runner.open(local: 49_200, remotePort: 5173)
        await runner.close(local: 49_200, remotePort: 5173)
        #expect(await ssh.calls.suffix(2) == [try argv(49_200, .cancel, .ipv4), try argv(49_200, .cancel, .ipv6)])
    }

    // MARK: - Process fallback

    private func process(_ tunnels: LeoFakeTunnels, ipv6: Bool = true) -> LeoProcessForwardRunner {
        LeoProcessForwardRunner(
            host: .remote("Build"),
            command: Self.command,
            sshExecutable: Self.ssh,
            prober: FakePortProber(listening: [5173], ipv6Available: ipv6),
            makeTunnel: tunnels.factory
        )
    }

    @Test func processRunnerLaunchesOneSSHPerForward() async throws {
        let tunnels = LeoFakeTunnels()
        let runner = process(tunnels)
        try await runner.open(local: 49_200, remotePort: 5173)
        let launch = try #require(tunnels.all.first?.launch)
        #expect(launch.arguments == (try Self.command.forwardProcessArguments(local: 49_200, remotePort: 5173, addresses: [.ipv4, .ipv6])))
        #expect(runner.isOpen(local: 49_200))
    }

    @Test func processRunnerIsIPv4OnlyWhenTheMachineHasNoIPv6Loopback() async throws {
        let tunnels = LeoFakeTunnels()
        try await process(tunnels, ipv6: false).open(local: 49_200, remotePort: 5173)
        let launch = try #require(tunnels.all.first?.launch)
        #expect(launch.arguments == (try Self.command.forwardProcessArguments(local: 49_200, remotePort: 5173, addresses: [.ipv4])))
    }

    @Test func processRunnerRelaunchesIPv4OnlyWhenTheIPv6ListenerCannotBind() async throws {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@build.example", .fails("bind [::1]:5173: Cannot assign requested address"), .ready)
        let runner = process(tunnels)
        try await runner.open(local: 5173, remotePort: 5173)
        #expect(tunnels.all.count == 2)
        #expect(tunnels.all.last?.launch.arguments == (try Self.command.forwardProcessArguments(local: 5173, remotePort: 5173, addresses: [.ipv4])))
        #expect(runner.isOpen(local: 5173))
    }

    @Test func processRunnerReadinessIsThePortAccepting() async throws {
        let tunnels = LeoFakeTunnels()
        try await process(tunnels).open(local: 5173, remotePort: 5173)
        let probe = try #require(tunnels.all.first?.launch.healthProbe)
        #expect(try await probe("ignored"))
    }

    @Test func processRunnerMapsABindFailureToPortBusy() async {
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@build.example", .fails("bind [127.0.0.1]:5173: Address already in use"))
        await #expect(throws: LeoPortForwardError.portBusy) {
            try await process(tunnels).open(local: 5173, remotePort: 5173)
        }
    }

    @Test func processRunnerCloseTerminatesTheProcess() async throws {
        let tunnels = LeoFakeTunnels()
        let runner = process(tunnels)
        try await runner.open(local: 49_200, remotePort: 5173)
        await runner.close(local: 49_200, remotePort: 5173)
        #expect(tunnels.all.first?.terminationCount == 1)
        #expect(!runner.isOpen(local: 49_200))
    }

    @Test func processRunnerNoticesADeadProcess() async throws {
        let tunnels = LeoFakeTunnels()
        let runner = process(tunnels)
        try await runner.open(local: 49_200, remotePort: 5173)
        tunnels.all.first?.exit()
        #expect(!runner.isOpen(local: 49_200))
    }
}
