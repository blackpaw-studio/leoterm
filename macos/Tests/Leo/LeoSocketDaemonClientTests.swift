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
}

private actor RecordingTransport: LeoDaemonTransport {
    var requests: [LeoHTTPRequest] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        let body: String
        if request.path == "/agents/list" {
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
