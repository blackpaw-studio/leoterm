import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Records every ssh invocation and answers with a scripted result.
actor RecordingForwardSSH: LeoProcessRunning {
    private(set) var calls: [[String]] = []
    private let status: Int32
    private let stderr: String

    init(status: Int32 = 0, stderr: String = "") {
        self.status = status
        self.stderr = stderr
    }

    func run(executable _: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append(arguments)
        return LeoProcessResult(stdout: Data(), stderr: Data(stderr.utf8), status: status)
    }
}

struct LeoPortForwardRunnerTests {
    private static let configuration = LeoHostConfiguration(name: "Build", sshTarget: "evan@build.example")
    private static let command = LeoSSHCommand(configuration: configuration)
    private static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    private func mux(_ ssh: RecordingForwardSSH) -> LeoMuxForwardRunner {
        LeoMuxForwardRunner(command: Self.command, controlPath: "/tmp/cm-build", runner: ssh, sshExecutable: Self.ssh)
    }

    @Test func openRunsForwardThroughTheControlMaster() async throws {
        let ssh = RecordingForwardSSH()
        try await mux(ssh).open(local: 5173, remotePort: 5173)
        let calls = await ssh.calls
        #expect(calls == [try Self.command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: 5173, op: .forward)])
    }

    @Test func status255MeansThePortIsBusy() async {
        let ssh = RecordingForwardSSH(status: 255, stderr: "Port forwarding failed")
        await #expect(throws: LeoPortForwardError.portBusy) {
            try await mux(ssh).open(local: 5173, remotePort: 5173)
        }
    }

    @Test func otherFailuresCarryStderr() async {
        let ssh = RecordingForwardSSH(status: 1, stderr: "mux_client_request_session: boom")
        await #expect(throws: LeoPortForwardError.failed("mux_client_request_session: boom")) {
            try await mux(ssh).open(local: 5173, remotePort: 5173)
        }
    }

    @Test func closeIssuesCancelForTheSameForward() async throws {
        let ssh = RecordingForwardSSH()
        await mux(ssh).close(local: 49_200, remotePort: 5173)
        let calls = await ssh.calls
        #expect(calls == [try Self.command.forwardArguments(controlPath: "/tmp/cm-build", local: 49_200, remotePort: 5173, op: .cancel)])
    }

    // MARK: - Process fallback

    private func process(_ tunnels: LeoFakeTunnels) -> LeoProcessForwardRunner {
        LeoProcessForwardRunner(
            host: .remote("Build"),
            command: Self.command,
            sshExecutable: Self.ssh,
            prober: FakePortProber(listening: [5173]),
            makeTunnel: tunnels.factory
        )
    }

    @Test func processRunnerLaunchesOneSSHPerForward() async throws {
        let tunnels = LeoFakeTunnels()
        let runner = process(tunnels)
        try await runner.open(local: 49_200, remotePort: 5173)
        let launch = try #require(tunnels.all.first?.launch)
        #expect(launch.arguments == (try Self.command.forwardProcessArguments(local: 49_200, remotePort: 5173)))
        #expect(runner.isOpen(local: 49_200))
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
