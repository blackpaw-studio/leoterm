import Foundation
import Testing

@testable import LeoKit

/// The service routes of the config API (status, restart, restart agents,
/// log, reload): their bodies decoded, and the requests the client sends.
struct LeoServiceAPITests {
    private static func client(prefix: String, _ transport: ConfigRecordingTransport) -> LeoConfigHTTPClient {
        LeoConfigHTTPClient(prefix: prefix, transport: transport)
    }

    // MARK: bodies

    @Test func theGoldenStatusDecodes() throws {
        let status = try LeoConfigFixtures.decode(LeoServiceStatus.self, "service_status")

        #expect(status.version == "v0.0.0-golden")
        #expect(status.pid == 1234)
        #expect(status.startedAt == Date(timeIntervalSince1970: 1_792_738_800))
        #expect(status.configPath == "<home>/leo.yaml")
        #expect(status.logPath.isEmpty)
        #expect(status.restartRequired == LeoConfigRestartRequired())
        #expect(status.processes.isEmpty)
        #expect(status.runningAgentCount == 0)
    }

    @Test func aBusyStatusCountsOnlyTheRunningAgents() throws {
        let status = try LeoConfigFixtures.decode(LeoServiceStatus.self, "service_status_busy")

        #expect(status.processes.map(\.name) == ["coder", "reviewer", "scratch", "old"])
        #expect(status.processes.map(\.status) == ["running", "restarting", "running", "stopped"])
        #expect(status.processes.map(\.isEphemeral) == [false, false, true, false])
        #expect(status.processes[1].restarts == 2)
        #expect(status.runningAgentCount == 2)
        #expect(status.restartRequired == LeoConfigRestartRequired(service: false, agents: true))
        #expect(status.startedAt != nil)
    }

    @Test func aStatusFromANewerDaemonWithMissingFieldsStillDecodes() throws {
        let body = #"{"ok": true, "data": {"version": "v9", "pid": 7}}"#
        let status = try LeoDaemonEnvelope<LeoServiceStatus>.decode(Data(body.utf8)).value()

        #expect(status.pid == 7)
        #expect(status.startedAt == nil)
        #expect(status.processes.isEmpty)
    }

    @Test func aDifferentPidOrStartTimeMeansTheDaemonRestarted() throws {
        let before = try LeoConfigFixtures.decode(LeoServiceStatus.self, "service_status_busy")
        let samePid = LeoServiceStatus(version: "v", pid: before.pid, startedAt: before.startedAt.map { $0.addingTimeInterval(60) })
        let newPid = LeoServiceStatus(version: "v", pid: before.pid + 1, startedAt: before.startedAt)

        #expect(!before.isRestarted(since: before))
        #expect(samePid.isRestarted(since: before))
        #expect(newPid.isRestarted(since: before))
    }

    @Test func restartAgentsAnswersWhoRestartedAndWhoFailed() throws {
        let ok = try LeoConfigFixtures.decode(LeoAgentsRestartResult.self, "service_restart_agents")
        let failed = try LeoConfigFixtures.decode(LeoAgentsRestartResult.self, "service_restart_agents_failed")

        #expect(ok.restarted == ["coder", "scratch"])
        #expect(ok.skipped == ["old"])
        #expect(!ok.hasFailures)
        #expect(failed.failed == ["reviewer": "tmux: no server running"])
        #expect(failed.hasFailures)
    }

    @Test func theLogAndReloadBodiesDecode() throws {
        let log = try LeoConfigFixtures.decode(LeoServiceLog.self, "service_log")
        let reload = try LeoConfigFixtures.decode(LeoConfigReload.self, "config_reload")

        #expect(log.text.hasPrefix("2026-10-23T07:00:00Z level=info"))
        #expect(reload.revision.hasPrefix("sha256:"))
        #expect(reload.warning == nil)
    }

    @Test func restartInProgressIsRecognisedFromTheDaemonsError() async throws {
        let body = try #require(String(bytes: try LeoConfigFixtures.data("error_restart_in_progress"), encoding: .utf8))
        let client = Self.client(prefix: "", ConfigRecordingTransport(body: body, status: 409))

        do {
            _ = try await client.restartService()
            Issue.record("expected a throw")
        } catch {
            #expect(LeoServiceError.isRestartInProgress(error))
            #expect(!LeoServiceError.isRestartInProgress(LeoConfigError.conflict(currentRevision: "r")))
        }
    }

    // MARK: routes

    @Test(arguments: LeoConfigClientTests.prefixes)
    func theServiceRoutes(prefix: String) async throws {
        let transport = ConfigRecordingTransport { request in
            switch request.path.split(separator: "?")[0].split(separator: "/").last {
            case "status": "service_status_busy"
            case "restart": "service_restart"
            case "restart-agents": "service_restart_agents"
            case "log": "service_log"
            default: "config_reload"
            }
        }
        let client = Self.client(prefix: prefix, transport)

        _ = try await client.serviceStatus()
        _ = try await client.restartService()
        _ = try await client.restartAgents()
        _ = try await client.serviceLog(lines: 200)
        _ = try await client.reloadConfig()

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST", "POST", "GET", "POST"])
        #expect(requests.map(\.path) == [
            "\(prefix)/service/status", "\(prefix)/service/restart", "\(prefix)/service/restart-agents",
            "\(prefix)/service/log?lines=200", "\(prefix)/config/reload",
        ])
        #expect(requests.allSatisfy { $0.headers.isEmpty && $0.body == nil })
    }

    @Test func theLogRequestIsAtLeastOneLine() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["service_log"])
        _ = try await Self.client(prefix: "", transport).serviceLog(lines: 0)

        #expect(await transport.requests.first?.path == "/service/log?lines=1")
    }
}
