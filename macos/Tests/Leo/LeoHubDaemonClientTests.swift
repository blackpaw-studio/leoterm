import Foundation
import Testing

@testable import Ghostty

struct LeoHubDaemonClientTests {
    @Test(arguments: [("0.27.0", LeoAPIFlavor.legacy), ("0.29.0", .hub), ("0.29.1", .hub), ("0.30.0", .hub), ("v0.29.0", .hub), ("garbage", .legacy)])
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

    @Test func hostRoutesEncodeSlashAndSpaceInOneSegment() async throws {
        let transport = HubRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        _ = try await client.listAgents(host: .remote("work / host"))
        _ = try await client.stop("agent / one", host: .remote("work / host"), wakeOnMessage: true)
        #expect(await transport.paths == [
            "/hosts/work%20%2F%20host/agents/list",
            "/hosts/work%20%2F%20host/agents/agent%20%2F%20one/stop"
        ])
    }

    @Test func hubStateAcceptsBareAndEnvelopedResponses() async throws {
        var bareScript = FakeHubScript()
        bareScript.state = Data(#"{"agents":[{"name":"bare"}]}"#.utf8)
        let bareDaemon = try FakeHubDaemon(script: bareScript)
        #expect(try await LeoHubActivityClient(socketPath: bareDaemon.path).fetchState().map(\.name) == ["bare"])

        var envelopeScript = FakeHubScript()
        envelopeScript.state = Data(#"{"ok":true,"data":{"agents":[{"name":"wrapped"}]}}"#.utf8)
        let envelopeDaemon = try FakeHubDaemon(script: envelopeScript)
        #expect(try await LeoHubActivityClient(socketPath: envelopeDaemon.path).fetchState().map(\.name) == ["wrapped"])
    }

    @Test func sshHintQuotesTarget() throws {
        #expect(try LeoCommandLauncher.sshHintCommand(target: "evan@host name") == "ssh 'evan@host name'")
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
