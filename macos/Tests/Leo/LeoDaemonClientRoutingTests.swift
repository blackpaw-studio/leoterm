import Foundation
import Testing

@testable import Ghostty

/// `LeoSocketDaemonClient` is bound to a single socket path and every route
/// is unprefixed -- there is no more `/hosts/{n}/...` multiplexing. A
/// host-scoped call for anything other than `.local` has nothing to route to
/// (that's app-owned SSH tunnels' job, landing in a later sub-round) and
/// throws `hostUnavailable` without making a request.
struct LeoDaemonClientRoutingTests {
    @Test func localHostUsesUnprefixedRoutes() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .legacy)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list"])
    }

    @Test func remoteHostThrowsHostUnavailableWithoutARequest() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .socketEvents)
        await #expect(throws: LeoDaemonError.hostUnavailable("Remote hosts are unavailable")) {
            _ = try await client.listAgents(host: .remote("work"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func templatesUsesUnprefixedLocalRoute() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .socketEvents)
        _ = try await client.templates()
        #expect(await transport.requests.map(\.path) == ["/templates"])
    }

    @Test func versionUsesUnprefixedRoute() async throws {
        let transport = RoutingRecordingTransport(body: Data(#"{"ok":true,"data":{"version":"0.29.0"}}"#.utf8))
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .socketEvents)
        let version = try await client.version()
        #expect(version == "0.29.0")
        #expect(await transport.requests.map(\.path) == ["/version"])
    }

    @Test func detectFlavorRequiresOkAndAParseableVersion() async throws {
        let socketEvents = HealthTransport(body: Data(#"{"ok":true,"data":{"version":"0.29.0"}}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: socketEvents) == .socketEvents)

        let notOK = HealthTransport(body: Data(#"{"ok":false,"data":{"version":"0.29.0"}}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: notOK) == .legacy)

        let bareOK = HealthTransport(body: Data(#"{"ok":true}"#.utf8))
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: bareOK) == .legacy)

        let unreachable = FailingTransport()
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: "/tmp/leo.sock", transport: unreachable) == .legacy)
    }

    @Test func makeClientConfiguresConstantFlavor() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoRuntime.makeClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .socketEvents)
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
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        LeoHTTPResponse(status: 200, body: body)
    }
}

private struct FailingTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        throw LeoDaemonError.transport("unreachable")
    }
}
