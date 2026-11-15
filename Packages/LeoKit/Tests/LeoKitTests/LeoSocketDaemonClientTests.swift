import Foundation
import Testing

@testable import LeoKit

struct LeoSocketDaemonClientTests {
    @Test func constructsEveryDaemonRoute() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.listAgents()
        _ = try await client.spawn(LeoSpawnRequest(template: "swift"))
        try await client.start("a/b")
        try await client.stop("a", wakeOnMessage: true)
        _ = try await client.restart("a")
        try await client.reset("a")
        try await client.setTemplate("a", template: "two words")
        _ = try await client.rename("a", newName: "b")
        try await client.delete("a", force: true, deleteBranch: false)
        _ = try await client.deletePlan("a")
        _ = try await client.logs("a", lines: 10)
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST", "POST", "POST", "POST", "POST", "POST", "POST", "DELETE", "GET", "GET"])
        #expect(requests.map(\.path) == ["/agents/list", "/agents/spawn", "/agents/a%2Fb/start", "/agents/a/stop", "/agents/a/restart", "/agents/a/reset", "/agents/a/set-template?template=two%20words", "/agents/a/rename", "/agents/a", "/agents/a/delete-plan", "/agents/a/logs?lines=10"])
    }

    /// B-176: a worktree spawn is the daemon's `branch` field (what
    /// `leo agent spawn --worktree` sends), with no `base` so the branch
    /// starts from origin HEAD.
    @Test func branchEncodesAsWorktreeField() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.spawn(LeoSpawnRequest(template: "claude", repo: "o/r", branch: "feat/x"))
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/spawn")
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["branch"] as? String == "feat/x")
        #expect(json["repo"] as? String == "o/r")
        #expect(json["template"] as? String == "claude")
        #expect(json["base"] == nil)
        #expect(Set(json.keys) == ["template", "repo", "branch"])
    }

    /// B-283: the set route takes the ordered names; an empty list clears.
    @Test func setEnvironmentsPostsOrderedNames() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.setEnvironments("a b", names: ["zeta", "alpha"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/agents/a%20b/environments")
        let json = try Self.object(request)
        #expect(json["environments"] as? [String] == ["zeta", "alpha"])
    }

    @Test(arguments: [
        (400, #"{"ok":false,"error":"unknown environment \"nope\"","code":"unknown_environment"}"#, #"unknown environment "nope""#),
        (409, #"{"ok":false,"error":"agent runs a persistent task","code":"persistent_task"}"#, "agent runs a persistent task"),
        (409, #"{"ok":false,"error":"environment aws is for codex","code":"harness_mismatch"}"#, "environment aws is for codex"),
        (403, #"{"ok":false,"error":"operator token required"}"#, "operator token required"),
        (500, #"{"ok":false,"error":"template not found"}"#, "template not found"),
        (500, "Internal Server Error", "HTTP 500"),
    ])
    func environmentErrorsShowDaemonMessage(status: Int, body: String, message: String) async throws {
        let transport = RecordingTransport(reply: LeoHTTPResponse(status: status, body: Data(body.utf8)))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect { try await client.setEnvironments("a", names: ["x"]) } throws: { error in
            (error as? LeoDaemonError)?.errorDescription == message
        }
        await #expect { _ = try await client.spawn(LeoSpawnRequest(template: "t", environments: ["x"])) } throws: { error in
            (error as? LeoDaemonError)?.errorDescription == message
        }
    }

    @Test func spawnOmitsEnvironmentsWhenNil() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.spawn(LeoSpawnRequest(template: "claude"))
        _ = try await client.spawn(LeoSpawnRequest(template: "claude", environments: ["b", "a"]))
        let bodies = try await transport.requests.map(Self.object)
        #expect(bodies[0]["environments"] == nil)
        #expect(bodies[1]["environments"] as? [String] == ["b", "a"])
        #expect(bodies[1]["template"] as? String == "claude")
    }

    private static func object(_ request: LeoHTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func environmentCatalogReadsNamesAndTemplateDefaults() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        let catalog = try await client.environmentCatalog()
        #expect(catalog == LeoEnvironmentCatalog(names: ["aws", "prod"], templateDefaults: ["claude": ["prod"]]))
        #expect(await transport.requests.map(\.path) == ["/environments", "/templates"])
    }

    @Test func machineStatsReadsTheMachineRoute() async throws {
        let transport = RecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        let stats = try await client.machineStats()
        #expect(stats.cpu?.cores == 8)
        #expect(stats.disk == nil)
        #expect(await transport.requests.map(\.method) == ["GET"])
        #expect(await transport.requests.map(\.path) == ["/machine"])
    }

    @Test func machineStatsUnavailableKeepsTheDaemonCode() async {
        let body = #"{"ok":false,"error":"stats unavailable","code":"machine_stats_unavailable"}"#
        let transport = RecordingTransport(reply: LeoHTTPResponse(status: 503, body: Data(body.utf8)))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect(throws: LeoDaemonError.daemon(code: LeoMachineStats.unavailableCode, message: "stats unavailable", matches: [])) {
            _ = try await client.machineStats()
        }
    }

    @Test func machineStatsDefaultsToUnavailableOnAClientWithoutIt() async {
        await #expect(throws: LeoDaemonError.transport("Machine stats are unavailable")) {
            _ = try await StatslessClient().machineStats()
        }
    }

    @Test func responseParserHandlesHTTPFraming() throws {
        let contentLength = try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest".utf8))
        #expect(contentLength.body == Data("test".utf8))
        let chunked = try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n".utf8))
        #expect(chunked.body == Data("test".utf8))
        #expect(throws: LeoDaemonError.decoding("Truncated HTTP body")) {
            try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nte".utf8))
        }
    }

    private func moveClient(status: Int, body: String) -> (LeoSocketDaemonClient, RecordingTransport) {
        let transport = RecordingTransport(reply: LeoHTTPResponse(status: status, body: Data(body.utf8)))
        return (LeoSocketDaemonClient(socketPath: "/tmp/s", transport: transport), transport)
    }

    private static let jobBody = #"{"id":"mv-1","request":{"mode":"move","to":"nas"},"state":"running"}"#

    @Test func startMovePostsTheRequestAndDecodesTheBareJob() async throws {
        let (client, transport) = moveClient(status: 202, body: Self.jobBody)
        let job = try await client.startMove("a b", .move(to: "nas"))
        #expect(job.id == "mv-1")
        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/agents/a%20b/move")
        let body = try #require(sent.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == ["mode": "move", "to": "nas"] as NSDictionary)
    }

    @Test func moveJobGetsTheJobById() async throws {
        let (client, transport) = moveClient(status: 200, body: Self.jobBody)
        _ = try await client.moveJob(id: "mv-1")
        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.path == "/moves/mv-1")
    }

    @Test func aMoveRefusalKeepsTheDaemonCodeAndText() async {
        let (client, _) = moveClient(status: 409, body: #"{"error":"agent_moving","message":"a is already being moved"}"#)
        await #expect(throws: LeoDaemonError.daemon(code: "agent_moving", message: "a is already being moved", matches: [])) {
            _ = try await client.startMove("a", .duplicate())
        }
    }

    @Test func aPlainTextNotFoundMeansAnOlderDaemon() async {
        let (client, _) = moveClient(status: 404, body: "404 page not found\n")
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: LeoMoveWire.unsupportedMessage, matches: [])) {
            _ = try await client.startMove("a", .duplicate())
        }
    }

    @Test func anUnknownJobPollIsNotFound() async {
        let (client, _) = moveClient(status: 404, body: #"{"error":"bad_request","message":"no such move job"}"#)
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "no such move job", matches: [])) {
            _ = try await client.moveJob(id: "mv-1")
        }
    }

    @Test func daemonErrorsPreserveCodeAndMatches() throws {
        let envelope = try LeoDaemonEnvelope<LeoAgent>.decode(Data(#"{"ok":false,"error":"ambiguous","code":"ambiguous","matches":["one","two"]}"#.utf8))
        #expect(throws: LeoDaemonError.daemon(code: "ambiguous", message: "ambiguous", matches: ["one", "two"])) {
            try envelope.value()
        }
    }
}

private actor RecordingTransport: LeoDaemonTransport {
    var requests: [LeoHTTPRequest] = []
    private let reply: LeoHTTPResponse?

    init(reply: LeoHTTPResponse? = nil) { self.reply = reply }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        if let reply { return reply }
        let body: String
        if request.path == "/environments" {
            body = #"{"ok":true,"data":[{"name":"prod"},{"name":"aws"}]}"#
        } else if request.path == "/templates" {
            body = #"{"ok":true,"data":[{"name":"claude","environments":["prod"]}]}"#
        } else if request.path == "/machine" {
            body = #"{"ok":true,"data":{"sampled_at":"2026-10-21T12:00:00Z","cpu":{"percent":null,"cores":8},"memory":{"used_bytes":1,"total_bytes":2},"disk":null}}"#
        } else if request.path == "/agents/list" {
            body = #"{"ok":true,"data":[]}"#
        } else if request.path == "/agents/spawn" || request.path.hasSuffix("/restart") || request.path.hasSuffix("/rename") {
            body = #"{"ok":true,"data":{"name":"a"}}"#
        } else if request.path.hasSuffix("/delete-plan") {
            body = #"{"ok":true,"data":{"name":"a","has_worktree":false}}"#
        } else if request.path.hasSuffix("/logs?lines=10") {
            body = #"{"ok":true,"data":{"output":"log"}}"#
        } else {
            body = #"{"ok":true}"#
        }
        return LeoHTTPResponse(status: 200, body: Data(body.utf8))
    }
}

/// A client that implements nothing, so every route falls to its protocol default.
private struct StatslessClient: LeoDaemonClient {
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
