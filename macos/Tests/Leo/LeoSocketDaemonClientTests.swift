import Foundation
import Testing

@testable import Ghostty

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

    @Test func responseParserHandlesHTTPFraming() throws {
        let contentLength = try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest".utf8))
        #expect(contentLength.body == Data("test".utf8))
        let chunked = try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n".utf8))
        #expect(chunked.body == Data("test".utf8))
        #expect(throws: LeoDaemonError.decoding("Truncated HTTP body")) {
            try LeoHTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nte".utf8))
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
