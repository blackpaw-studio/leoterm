import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Test Connection on a throwaway connection: ssh, then the tunnel with its
/// `/health` probe, `/version`, and one bounded read of the `/events` hello
/// for `machine_stats`. The live connection of the same machine is never
/// touched.
@MainActor struct LeoMachineConnectionTesterTests {
    private let work = LeoHostConfiguration(name: "work", sshTarget: "evan@work.lan")

    @Test func aHealthyMachineReportsEveryStepAndTearsItsTunnelDown() async throws {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: ["agent_environments", "machine_stats"]))

        let report = await rig.tester.test(work)

        #expect(report.succeeded)
        #expect(report.outcome(for: .ssh) == .passed("work.lan reachable as evan"))
        #expect(report.outcome(for: .daemon) == .passed("leo 0.57.0 answered"))
        #expect(report.outcome(for: .machineStats) == .passed("Available (machine_stats)"))
        let tunnel = try #require(rig.tunnels.all.first)
        #expect(rig.tunnels.all.count == 1)
        #expect(tunnel.terminationCount == 1, "the throwaway ssh process is gone when the test ends")
    }

    @Test func theThrowawayConnectionNeverSharesSocketsWithTheMachinesLiveConnection() async throws {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: []))

        _ = await rig.tester.test(work)

        let launch = try #require(rig.tunnels.all.first?.launch)
        #expect(launch.localSocketPath != rig.environment.tunnelSocketPath(for: work))
        #expect(!launch.arguments.contains(rig.environment.controlPath(for: work)))
    }

    @Test func aDaemonWithoutMachineStatsStillConnects() async {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.50.0", helloFeatures: ["agent_environments"]))

        let report = await rig.tester.test(work)

        #expect(report.succeeded)
        guard case .unavailable = report.outcome(for: .machineStats) else {
            Issue.record("expected unavailable, got \(report.outcome(for: .machineStats))")
            return
        }
    }

    @Test func aFailingSshStepStopsTheTestBeforeAnyTunnelIsBuilt() async {
        let rig = Rig(
            transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: []),
            runner: FailingSSHRunner(stderr: "ssh: connect to host work.lan port 22: Operation timed out\n")
        )

        let report = await rig.tester.test(work)

        #expect(!report.succeeded)
        #expect(report.outcome(for: .ssh) == .failed(LeoSFTPServerText.isolated("ssh: connect to host work.lan port 22: Operation timed out")))
        #expect(report.outcome(for: .daemon) == .notTested)
        #expect(report.outcome(for: .machineStats) == .notTested)
        #expect(rig.tunnels.all.isEmpty)
    }

    @Test func aTunnelThatNeverBecomesReadyFailsTheDaemonStepAfterSshPassed() async {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: []))
        rig.tunnels.script("evan@work.lan", .fails("bind: Address already in use"))

        let report = await rig.tester.test(work)

        #expect(!report.succeeded)
        guard case .passed = report.outcome(for: .ssh), case .failed(let detail) = report.outcome(for: .daemon) else {
            Issue.record("expected ssh passed and daemon failed, got \(report)")
            return
        }
        #expect(detail.contains("Address already in use"))
        #expect(report.outcome(for: .machineStats) == .notTested)
    }

    @Test func aDaemonThatDoesNotAnswerVersionFailsTheDaemonStep() async {
        let rig = Rig(transport: ScriptedDaemonTransport(version: nil, helloFeatures: []))

        let report = await rig.tester.test(work)

        #expect(!report.succeeded)
        guard case .failed = report.outcome(for: .daemon) else {
            Issue.record("expected a failed daemon step, got \(report.outcome(for: .daemon))")
            return
        }
        #expect(rig.tunnels.all.first?.terminationCount == 1)
    }

    @Test func aTunnelThatHangsTimesOutAndIsTornDown() async throws {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: []))
        rig.tunnels.script("evan@work.lan", .hangs)

        let running = Task { await rig.tester.test(work) }
        await awaitCondition { rig.sleeper.requested.contains(.seconds(20)) && rig.sleeper.pendingCount == 1 }
        rig.sleeper.fireAll()
        let report = await running.value

        #expect(!report.succeeded)
        #expect(report.outcome(for: .daemon) == .failed("Timed out waiting for the daemon"))
        #expect(rig.tunnels.all.first?.terminationCount == 1)
    }

    @Test func aSilentEventStreamLeavesStatsUnavailableWithoutFailingTheMachine() async {
        let rig = Rig(transport: ScriptedDaemonTransport(version: "0.57.0", helloFeatures: nil))

        let running = Task { await rig.tester.test(work) }
        await awaitCondition { rig.sleeper.requested.contains(.seconds(3)) && rig.sleeper.pendingCount == 1 }
        rig.sleeper.fireAll()
        let report = await running.value

        #expect(report.succeeded)
        #expect(report.outcome(for: .machineStats) == .unavailable("The daemon sent no hello"))
    }

    // MARK: Fixtures

    @MainActor private struct Rig {
        let tunnels = LeoFakeTunnels()
        let sleeper = LeoManualSleeper()
        let environment: LeoMachineConnectionEnvironment
        let tester: LeoMachineConnectionTester

        init(transport: ScriptedDaemonTransport, runner: any LeoProcessRunning = LeoFakeHomeRunner(stdout: "/home/evan")) {
            let environment = LeoMachineRegistryTestSupport.environment(
                defaults: LeoInMemoryDefaults(), tunnels: tunnels, runner: runner, transport: transport
            )
            self.environment = environment
            tester = LeoMachineConnectionTester(
                environment: environment, activityTransport: transport, sleep: { [sleeper] in try await sleeper.sleep($0) }
            )
        }
    }
}

private struct FailingSSHRunner: LeoProcessRunning {
    let stderr: String

    func run(executable _: String, arguments _: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        LeoProcessResult(stdout: Data(), stderr: Data(stderr.utf8), status: 255)
    }
}

/// Answers `/health` and `/version`, and streams `/events` with a hello
/// advertising `helloFeatures` (nil: the stream stays open and silent).
private struct ScriptedDaemonTransport: LeoSocketActivityTransport {
    let version: String?
    let helloFeatures: [String]?

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        switch request.path {
        case "/health":
            return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        case "/version":
            guard let version else { return LeoHTTPResponse(status: 404, body: Data(#"{"ok":false,"error":"not found"}"#.utf8)) }
            return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":{"version":"\#(version)"}}"#.utf8))
        default:
            return LeoHTTPResponse(status: 404, body: Data())
        }
    }

    func stream(path _: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard let helloFeatures else { return }
            let features = helloFeatures.map { "\"\($0)\"" }.joined(separator: ",")
            continuation.yield(Data("event: hello\ndata: {\"seq\":1,\"version\":\"0.57.0\",\"features\":[\(features)]}\n\n".utf8))
        }
    }
}
