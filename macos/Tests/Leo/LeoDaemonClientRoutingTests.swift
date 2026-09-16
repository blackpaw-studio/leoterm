import Foundation
import Testing

@testable import Ghostty

/// Covers the flavor-aware routing bug: host-scoped daemon calls must route
/// differently depending on whether the daemon is a legacy (0.27) or hub
/// (0.29+) daemon, and `LeoRuntime` must actually pass the detected flavor
/// into the concrete client it hands to the rest of the app.
struct LeoDaemonClientRoutingTests {
    @Test func legacyLocalHostUsesUnprefixedRoute() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .legacy)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list"])
    }

    @Test func legacyRemoteHostThrowsHubRequiredWithoutARequest() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .legacy)
        await #expect(throws: LeoDaemonError.hubRequired("leo 0.29+ required for remote hosts")) {
            _ = try await client.listAgents(host: .remote("work"))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func hubLocalHostUsesPrefixedRoute() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/hosts/localhost/agents/list"])
    }

    @Test func hubRemoteHostUsesPrefixedRoute() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        _ = try await client.listAgents(host: .remote("x"))
        #expect(await transport.requests.map(\.path) == ["/hosts/x/agents/list"])
    }

    @Test func makeClientConfiguresConstantFlavor() async throws {
        let transport = RoutingRecordingTransport()
        let client = LeoRuntime.makeClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/hosts/localhost/agents/list"])
    }

    @Test func makeClientHonorsADynamicFlavorProvider() async throws {
        let transport = RoutingRecordingTransport()
        let state = LeoAPIFlavorState()
        let client = LeoRuntime.makeClient(socketPath: "/tmp/leo.sock", transport: transport, flavorProvider: { await state.current })

        // Before detection resolves, the provider still reports the safe default.
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list"])

        // Once the runtime records a detected hub flavor, the same client instance
        // routes hub-style without needing to be reconstructed.
        await state.update(.hub)
        _ = try await client.listAgents(host: .local)
        #expect(await transport.requests.map(\.path) == ["/agents/list", "/hosts/localhost/agents/list"])
    }
}

private actor RoutingRecordingTransport: LeoDaemonTransport {
    private(set) var requests: [LeoHTTPRequest] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":[]}"#.utf8))
    }
}
