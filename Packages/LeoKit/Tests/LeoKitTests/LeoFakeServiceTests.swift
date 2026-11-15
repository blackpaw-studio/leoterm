import Foundation
import Testing

@testable import LeoKit

/// The fake daemon's service behaviour, which the Mac models are tested against.
struct LeoFakeServiceTests {
    private static func fake() throws -> LeoFakeConfigClient {
        LeoFakeConfigClient(schema: try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema"))
    }

    @Test func statusReportsTheProcessAndThePendingRestarts() async throws {
        let fake = try Self.fake()
        await fake.setService(LeoFakeServiceState(pid: 10, processes: [LeoServiceProcess(name: "coder", status: "running")]))

        let status = try await fake.serviceStatus()
        #expect(status.pid == 10)
        #expect(status.runningAgentCount == 1)
        #expect(status.restartRequired == LeoConfigRestartRequired())
    }

    @Test func aRestartIsSingleFlightUntilTheDaemonComesBackWithANewPid() async throws {
        let fake = try Self.fake()
        await fake.setService(LeoFakeServiceState(pid: 10))
        let before = try await fake.serviceStatus()

        _ = try await fake.restartService()
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.restartService() }
        #expect(try await fake.serviceStatus().pid == before.pid)

        await fake.finishServiceRestart()
        let after = try await fake.serviceStatus()
        #expect(after.isRestarted(since: before))
        _ = try await fake.restartService()
    }

    @Test func aRestartClearsTheServiceFlagButNotTheAgentsOne() async throws {
        let fake = try Self.fake()
        await fake.setService(LeoFakeServiceState(pid: 10))
        await fake.raiseRestartRequired(LeoConfigRestartRequired(service: true, agents: true))
        _ = try await fake.restartService()
        await fake.finishServiceRestart()

        #expect(try await fake.serviceStatus().restartRequired == LeoConfigRestartRequired(service: false, agents: true))
    }

    @Test func restartAgentsClearsTheFlagOnlyWhenNothingFailed() async throws {
        let fake = try Self.fake()
        await fake.setService(LeoFakeServiceState(pid: 10, agentsRestart: LeoAgentsRestartResult(restarted: ["a"], failed: ["b": "boom"])))
        await fake.raiseRestartRequired(LeoConfigRestartRequired(service: false, agents: true))

        let failed = try await fake.restartAgents()
        #expect(failed.hasFailures)
        #expect(try await fake.serviceStatus().restartRequired.agents)

        await fake.setService(LeoFakeServiceState(pid: 10, agentsRestart: LeoAgentsRestartResult(restarted: ["a", "b"])))
        _ = try await fake.restartAgents()
        #expect(!(try await fake.serviceStatus().restartRequired.agents))
    }

    @Test func theLogIsWhatTheDaemonHolds() async throws {
        let fake = try Self.fake()
        await fake.setService(LeoFakeServiceState(pid: 1, log: "one\ntwo\n"))

        #expect(try await fake.serviceLog(lines: 200).text == "one\ntwo\n")
    }

    @Test func reloadAnswersTheCurrentRevision() async throws {
        let fake = try Self.fake()
        let reload = try await fake.reloadConfig()

        #expect(reload.revision == (await fake.currentRevision))
    }
}
