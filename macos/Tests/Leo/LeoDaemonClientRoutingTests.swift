import Foundation
import Testing

@testable import Ghostty

/// `LeoSocketDaemonClient` is bound to a single socket path and every route
/// is unprefixed -- there is no more per-host prefixed routing. A
/// host-scoped call for anything other than `.local` has nothing to route to
/// (that's app-owned SSH tunnels' job) and throws `hostUnavailable` without
/// making a request.
struct LeoDaemonClientRoutingTests {
    @Test func localHostUsesUnprefixedRoutes() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list"])
    }

    @Test func remoteHostThrowsHostUnavailableWithoutARequest() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect(throws: LeoDaemonError.hostUnavailable("Remote hosts are unavailable")) {
            _ = try await client.listAgents(host: .remote("work"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func templatesUsesUnprefixedLocalRoute() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.templates()
        #expect(await transport.requests.map(\.path) == ["/templates"])
    }

    @Test func versionUsesUnprefixedRoute() async throws {
        let transport = RoutingRecordingTransport(body: Data(#"{"ok":true,"data":{"version":"0.29.0"}}"#.utf8))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        let version = try await client.version()
        #expect(version == "0.29.0")
        #expect(await transport.requests.map(\.path) == ["/version"])
    }

    @Test func spawnSendsTheEncodedRequestBody() async throws {
        let transport = RoutingRecordingTransport(body: Data(#"{"ok":true,"data":{"name":"alpha"}}"#.utf8))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.spawn(.init(template: "swift", repo: "r", name: "alpha", branch: nil, prompt: nil))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/agents/spawn")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(LeoSpawnRequest.self, from: body)
        #expect(decoded.template == "swift")
        #expect(decoded.name == "alpha")
    }

    @Test func stopSendsWakeOnMessageInTheBody() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.stop("alpha", wakeOnMessage: true)
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/alpha/stop")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode([String: Bool].self, from: body)
        #expect(decoded == ["wake_on_message": true])
    }

    @Test func renameSendsNewNameInTheBody() async throws {
        let transport = RoutingRecordingTransport(body: Data(#"{"ok":true,"data":{"name":"bravo"}}"#.utf8))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.rename("alpha", newName: "bravo")
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/alpha/rename")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == ["new_name": "bravo"])
    }

    @Test func deleteOmitsTheBodyWhenNoOptionsAreGiven() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.delete("alpha", force: nil, deleteBranch: nil)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/agents/alpha")
        #expect(request.body == nil)
    }

    @Test func deleteSendsForceAndDeleteBranchWhenGiven() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        try await client.delete("alpha", force: true, deleteBranch: false)
        let request = try #require(await transport.requests.first)
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode([String: Bool].self, from: body)
        #expect(decoded == ["force": true, "delete_branch": false])
    }

    @Test(arguments: [
        ("0.27.0", LeoAPIFlavor.legacy),
        ("0.29.0", .socketEvents),
        ("0.29.0-rc1", .socketEvents),
        ("0.30.0", .socketEvents),
        ("1.0.0", .socketEvents),
        ("abc", .legacy)
    ])
    func detectFlavorSelectsBySemver(version: String, expected: LeoAPIFlavor) async throws {
        let transport = HealthTransport(body: Data(#"{"ok":true,"data":{"version":"\#(version)"}}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: transport) == expected)
    }

    @Test func detectFlavorRequiresOkAndAParseableVersion() async throws {
        let notOK = HealthTransport(body: Data(#"{"ok":false,"data":{"version":"0.29.0"}}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: notOK) == .legacy)

        let bareOK = HealthTransport(body: Data(#"{"ok":true}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: bareOK) == .legacy)

        let unreachable = FailingTransport()
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: unreachable) == .legacy)
    }

    /// A 500 with an otherwise-valid `{ok:true,data:{version}}` body must
    /// never be treated as a healthy `.socketEvents` daemon -- the status
    /// line is checked before the body is ever decoded.
    @Test func detectFlavorRequiresA2xxStatusEvenWithAValidBody() async throws {
        let transport = HealthTransport(body: Data(#"{"ok":true,"data":{"version":"0.29.0"}}"#.utf8), status: 500)
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: transport) == .legacy)
    }

    @Test func makeClientProducesAWorkingClient() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoRuntime.makeClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list"])
    }
}

private actor RoutingRecordingTransport: LeoDaemonTransport {
    private(set) var requests: [LeoHTTPRequest] = []
    private let body: Data

    init(body: Data = Data(#"{"ok":true,"data":[]}"#.utf8)) { self.body = body }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        return LeoHTTPResponse(status: 200, body: body)
    }
}

private struct HealthTransport: LeoDaemonTransport {
    let body: Data
    var status: Int = 200
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        LeoHTTPResponse(status: status, body: body)
    }
}

private struct FailingTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        throw LeoDaemonError.transport("unreachable")
    }
}
