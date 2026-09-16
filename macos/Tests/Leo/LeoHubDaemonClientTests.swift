import Foundation
import Testing

@testable import Ghostty

struct LeoHubDaemonClientTests {
    @Test(arguments: [("0.27", LeoAPIFlavor.legacy), ("0.29.0", .hub), ("0.30", .hub), ("nope", .legacy)])
    func versionGate(version: String, expected: LeoAPIFlavor) {
        #expect(LeoAPIFlavor.select(version: version) == expected)
    }

    @Test func hostRoutesEncodeAHostAsOneSegment() async throws {
        let transport = HubRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        _ = try await client.listAgents(host: .local)
        _ = try await client.listAgents(host: .remote("work host"))
        _ = try await client.templates(host: .remote("work host"))
        _ = try await client.connectHost("work host")
        _ = try await client.disconnectHost("work host")
        #expect(await transport.paths == [
            "/hosts/localhost/agents/list", "/hosts/work%20host/agents/list",
            "/hosts/work%20host/templates", "/hosts/work%20host/connect", "/hosts/work%20host/disconnect"
        ])
    }

    @Test func hostUnavailableGetsTypedError() async {
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: HubUnavailableTransport(), flavor: .hub)
        await #expect(throws: LeoDaemonError.hostUnavailable("offline")) {
            try await client.listAgents(host: .remote("work"))
        }
    }
}

private actor HubRecordingTransport: LeoDaemonTransport {
    private(set) var paths: [String] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        paths.append(request.path)
        let data: String
        if request.path.hasSuffix("/agents/list") || request.path.hasSuffix("/templates") {
            data = #"{"ok":true,"data":[]}"#
        } else {
            data = #"{"ok":true,"data":{"name":"work host","local":false,"default":false,"state":"connected"}}"#
        }
        return .init(status: 200, body: Data(data.utf8))
    }
}

private struct HubUnavailableTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 503, body: Data(#"{"ok":false,"code":"host_unavailable","error":"offline"}"#.utf8))
    }
}
