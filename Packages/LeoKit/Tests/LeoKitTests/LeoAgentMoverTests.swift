import Foundation
import Testing

@testable import LeoKit

struct LeoAgentMoverTests {
    private static func job(_ state: String, mode: String = "move", extra: String = "") -> LeoMoveJob {
        let json = #"{"id":"mv-1","request":{"mode":"\#(mode)","to":"nas"},"state":"\#(state)"\#(extra)}"#
        guard let job = try? JSONDecoder().decode(LeoMoveJob.self, from: Data(json.utf8)) else { fatalError("bad job fixture: \(json)") }
        return job
    }

    private func mover(_ client: ScriptedMoveClient, sleep: SleepProbe = SleepProbe()) -> LeoAgentMover {
        LeoAgentMover(client: client, pollInterval: .seconds(1), sleep: { try await sleep.sleep($0) })
    }

    @Test func pollsUntilDone() async throws {
        let sleeps = SleepProbe()
        let client = ScriptedMoveClient(start: .success(Self.job("running")), polls: [
            .success(Self.job("running")),
            .success(Self.job("done", extra: #","result":{"name":"a","to":"nas"}"#)),
        ])
        let outcome = try await mover(client, sleep: sleeps).run("a", .move(to: "nas"))
        #expect(outcome == .done(LeoMoveResult(name: "a", host: nil, to: "nas", workspace: nil, branch: nil)))
        #expect(await client.pollCount == 2)
        #expect(await sleeps.durations == [.seconds(1), .seconds(1)])
    }

    @Test func aBusyMoveIsRefusedWithForceOffered() async throws {
        let client = ScriptedMoveClient(start: .success(Self.job("running")), polls: [
            .success(Self.job("failed", extra: #","error":{"code":"agent_busy","message":"pass --force"}"#)),
        ])
        let outcome = try await mover(client).run("a", .move(to: "nas"))
        #expect(outcome == .refused(code: "agent_busy", message: "This agent is in the middle of a turn.", offersForce: true))
    }

    @Test func aBusyCopyOffersNoForce() async throws {
        let client = ScriptedMoveClient(start: .success(Self.job("running", mode: "copy")), polls: [
            .success(Self.job("failed", mode: "copy", extra: #","error":{"code":"agent_busy","message":"busy"}"#)),
        ])
        let outcome = try await mover(client).run("a", .copy(to: "nas"))
        #expect(outcome == .refused(code: "agent_busy", message: "This agent is in the middle of a turn.", offersForce: false))
    }

    @Test func preflightProblemsSurfaceTheDaemonsTextVerbatim() async throws {
        let client = ScriptedMoveClient(start: .success(Self.job("running")), polls: [
            .success(Self.job("failed", extra: #"""
            ,"error":{"code":"no_repo","message":"no_repo: not a git repo; same_host: already there"},
            "problems":[{"code":"no_repo","message":"not a git repo"},{"code":"same_host","message":"already there"}]
            """#)),
        ])
        let outcome = try await mover(client).run("a", .move(to: "nas"))
        #expect(outcome == .refused(code: "no_repo", message: "not a git repo\nalready there", offersForce: false))
    }

    @Test func aJobAlreadyFailedOnStartIsNotPolled() async throws {
        let client = ScriptedMoveClient(start: .success(Self.job("failed", extra: #","error":{"code":"name_taken","message":"taken"}"#)), polls: [])
        let outcome = try await mover(client).run("a", .duplicate(name: "x"))
        #expect(outcome == .refused(code: "name_taken", message: "taken", offersForce: false))
        #expect(await client.pollCount == 0)
    }

    @Test func aPollThatGetsNotFoundIsUnknown() async throws {
        let client = ScriptedMoveClient(start: .success(Self.job("running")), polls: [
            .failure(.daemon(code: "not_found", message: "no such move job", matches: [])),
        ])
        let outcome = try await mover(client).run("a", .move(to: "nas"))
        #expect(outcome == .unknown("no such move job"))
    }

    @Test func aStartRefusalThrowsTheDaemonError() async {
        let refusal = LeoDaemonError.daemon(code: "agent_moving", message: "already moving", matches: [])
        let client = ScriptedMoveClient(start: .failure(refusal), polls: [])
        await #expect(throws: refusal) { _ = try await mover(client).run("a", .move(to: "nas")) }
    }

    @Test func cancellationStopsPolling() async {
        let client = ScriptedMoveClient(start: .success(Self.job("running")), polls: Array(repeating: .success(Self.job("running")), count: 5))
        let sleeps = SleepProbe(cancelOnCall: 2)
        await #expect(throws: CancellationError.self) { _ = try await mover(client, sleep: sleeps).run("a", .move(to: "nas")) }
        #expect(await client.pollCount == 1)
    }
}

private actor SleepProbe {
    private(set) var durations: [Duration] = []
    private let cancelOnCall: Int?

    init(cancelOnCall: Int? = nil) { self.cancelOnCall = cancelOnCall }

    func sleep(_ duration: Duration) throws {
        durations.append(duration)
        if durations.count == cancelOnCall { throw CancellationError() }
    }
}

private actor ScriptedMoveClient: LeoDaemonClient {
    private let startResult: Result<LeoMoveJob, LeoDaemonError>
    private var polls: [Result<LeoMoveJob, LeoDaemonError>]
    private(set) var pollCount = 0

    init(start: Result<LeoMoveJob, LeoDaemonError>, polls: [Result<LeoMoveJob, LeoDaemonError>]) {
        startResult = start
        self.polls = polls
    }

    func startMove(_ name: String, _ request: LeoMoveRequest) async throws -> LeoMoveJob { try startResult.get() }
    func moveJob(id: String) async throws -> LeoMoveJob {
        pollCount += 1
        return try polls.removeFirst().get()
    }

    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.timeout }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
