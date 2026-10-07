import Foundation
import Testing

@testable import Ghostty

/// B-262: the four operator control routes on the daemon socket
/// (`POST /agents/{name}/{message,interrupt,compact,clear}`), through a stub
/// transport. The daemon's errors carry no `code`, so the HTTP status is what
/// names the failure.
struct LeoAgentControlClientTests {
    @Test func messagePostsTextToSocketRoute() async throws {
        let transport = ControlStubTransport(status: 200, body: #"{"ok":true,"data":{"transport":"bridge"}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        let delivery = try await client.message("autopilot-scratch", text: "hi")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/agents/autopilot-scratch/message")
        #expect(try JSONDecoder().decode([String: String].self, from: #require(request.body)) == ["text": "hi"])
        #expect(delivery == .delivered(transport: "bridge"))
    }

    @Test func message202DecodesQueued() async throws {
        let transport = ControlStubTransport(status: 202, body: #"{"ok":true,"data":{"queued":true}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        #expect(try await client.message("a", text: "hi") == .queued)
    }

    @Test func interruptPostsWithoutBody() async throws {
        let transport = ControlStubTransport(status: 200, body: #"{"ok":true,"data":{"transport":"bridge"}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.interrupt("a b")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/agents/a%20b/interrupt")
        #expect(request.body == nil)
    }

    @Test func compactSendsNoBodyWithoutInstructions() async throws {
        let transport = ControlStubTransport(status: 200, body: #"{"ok":true,"data":{}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.compact("a", instructions: nil)
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/a/compact")
        #expect(request.body == nil)
    }

    @Test func compactSendsInstructionsWhenGiven() async throws {
        let transport = ControlStubTransport(status: 200, body: #"{"ok":true,"data":{}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.compact("a", instructions: "keep tests")
        let body = try #require(await transport.requests.first?.body)
        #expect(try JSONDecoder().decode([String: String].self, from: body) == ["instructions": "keep tests"])
    }

    @Test func clearPostsToItsRoute() async throws {
        let transport = ControlStubTransport(status: 200, body: #"{"ok":true,"data":{}}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.clear("a")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/agents/a/clear")
    }

    @Test(arguments: [
        (401, "unauthorized"), (403, "forbidden"), (404, "not_found"),
        (413, "too_large"), (503, "unavailable"), (400, "http_400"), (500, "http_500"),
    ])
    func statusMapsToCodeAndKeepsDaemonMessage(status: Int, code: String) async throws {
        let transport = ControlStubTransport(status: status, body: #"{"ok":false,"error":"operator token required"}"#)
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect(throws: LeoDaemonError.daemon(code: code, message: "operator token required", matches: [])) {
            try await client.interrupt("a")
        }
    }

    @Test func nonJSONErrorBodyStillMapsByStatus() async throws {
        let transport = ControlStubTransport(status: 403, body: "Forbidden")
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect(throws: LeoDaemonError.daemon(code: "forbidden", message: "HTTP 403", matches: [])) {
            _ = try await client.message("a", text: "x")
        }
    }
}

private actor ControlStubTransport: LeoDaemonTransport {
    private(set) var requests: [LeoHTTPRequest] = []
    private let status: Int
    private let body: Data

    init(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        return LeoHTTPResponse(status: status, body: body)
    }
}
