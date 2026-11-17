import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoThisMacOverviewTests {
    private static func overview(
        managed: LeoManagedStatus = .managed(version: "0.49.2"), connection: LeoHostConnectionState? = .connected(socketPath: "/Users/e/.leo/state/leo.sock"),
        status: LeoMachineStatus? = .connected, service: LeoServiceStatus? = LeoServiceStatus(version: "v0.49.2", pid: 1, configPath: "/Users/e/.leo/leo.yaml"),
        agents: Int = 14, daemonVersion: String? = "0.50.0"
    ) -> LeoThisMacOverview {
        LeoThisMacOverview(
            managed: managed, presentation: LeoManagedPresentation(status: managed, notice: nil), connection: connection, status: status,
            service: service, agentCount: agents, daemonVersion: daemonVersion
        )
    }

    @Test func theSocketRowIsAbsentWhenNotConnected() {
        #expect(Self.overview().socketPath == "/Users/e/.leo/state/leo.sock")
        #expect(Self.overview(connection: .connecting, status: .connecting).socketPath == nil)
        #expect(Self.overview(connection: .failed(message: "gone", hint: nil), status: .failed("gone")).socketPath == nil)
        #expect(Self.overview(connection: nil, status: nil).socketPath == nil)
    }

    @Test func theConfigRowIsAbsentWithoutAServiceStatus() {
        #expect(Self.overview().configPath == "/Users/e/.leo/leo.yaml")
        #expect(Self.overview(service: nil).configPath == nil)
        #expect(Self.overview(service: LeoServiceStatus(version: "v1", pid: 1, configPath: "")).configPath == nil)
    }

    @Test func actionsFollowTheManagedStateAndTheConnection() {
        let offer = LeoManagedStatus.usingCLI(offerTakeover: true, isRunning: true)
        #expect(Self.overview(managed: offer).actions == [.banner(.takeOver), .banner(.notNow)])

        let offline = Self.overview(managed: .inactive, connection: .failed(message: "no socket", hint: nil), status: .failed("no socket"))
        #expect(offline.actions == [.start(.startCLIDaemon)])

        #expect(Self.overview(managed: .awaitingApproval).actions == [.banner(.openLoginItems)])
        #expect(Self.overview(managed: .managed(version: nil)).actions.isEmpty)
    }

    @Test func theReasonLineAppearsForAFailedConnection() {
        let failed = Self.overview(connection: .failed(message: "socket missing", hint: nil), status: .failed("socket missing"))
        #expect(failed.reason == "socket missing")
        #expect(Self.overview().reason == nil)
        #expect(Self.overview(status: .connecting).reason == nil)
    }

    @Test func theVersionPrefersTheManagedStateElseWhatTheDaemonReported() {
        #expect(Self.overview().version == "0.49.2")
        #expect(Self.overview(managed: .managed(version: nil)).version == "0.50.0")
        #expect(Self.overview(managed: .inactive).version == "0.50.0")
        #expect(Self.overview(managed: .inactive, daemonVersion: nil).version == nil)
    }

    @Test func theDaemonStateIsInWords() {
        #expect(Self.overview().daemon == .init(title: "Managed by Leo", detail: "Leo.app starts this daemon at login and updates it with the app."))
    }

    @Test func theAgentCountReadsNaturally() {
        #expect(Self.overview(agents: 0).agentCountText == "No agents")
        #expect(Self.overview(agents: 1).agentCountText == "1 agent")
        #expect(Self.overview(agents: 14).agentCountText == "14 agents")
    }
}
