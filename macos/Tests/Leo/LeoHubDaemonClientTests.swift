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

    @Test func hostUnknownGetsTypedError() async throws {
        var script = FakeHubScript()
        script.unknownHosts = ["missing"]
        let daemon = try FakeHubDaemon(script: script)
        let client = LeoSocketDaemonClient(socketPath: daemon.path, flavor: .hub)
        await #expect(throws: LeoDaemonError.hostUnknown("unknown host")) {
            try await client.listAgents(host: .remote("missing"))
        }
    }

    @Test(arguments: [
        (Optional("0.27.0"), false, 200, LeoAPIFlavor.legacy),
        (Optional("0.29.0"), false, 200, .hub),
        (Optional("0.29.1"), false, 200, .hub),
        (Optional("0.30.0"), false, 200, .hub),
        (Optional("v0.29.0"), false, 200, .hub),
        (Optional("garbage"), false, 200, .legacy),
        (nil, false, 200, .legacy),
        (Optional("0.29.0"), true, 200, .legacy),
        (Optional("0.29.0"), false, 500, .legacy)
    ])
    func versionGateReadsHealthEnvelope(version: String?, legacy: Bool, status: Int, expected: LeoAPIFlavor) async throws {
        var script = FakeHubScript()
        script.version = version
        script.legacyHealth = legacy
        script.healthStatus = status
        let daemon = try FakeHubDaemon(script: script)
        #expect(await LeoSocketDaemonClient.detectFlavor(socketPath: daemon.path) == expected)
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

    @Test func everyHostScopedMethodBuildsLocalAndEncodedRemoteRoutes() async throws {
        let transport = HubRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport, flavor: .hub)
        for host in [LeoHostID.local, .remote("work / host")] {
            _ = try await client.listAgents(host: host)
            _ = try await client.spawn(.init(), host: host)
            try await client.start("agent / one", host: host)
            try await client.stop("agent / one", host: host, wakeOnMessage: true)
            _ = try await client.restart("agent / one", host: host)
            try await client.reset("agent / one", host: host)
            try await client.setTemplate("agent / one", host: host, template: "swift / app")
            _ = try await client.rename("agent / one", host: host, newName: "renamed")
            try await client.delete("agent / one", host: host, force: true, deleteBranch: false)
            _ = try await client.deletePlan("agent / one", host: host)
            _ = try await client.logs("agent / one", host: host, lines: 20)
            _ = try await client.templates(host: host)
        }
        let paths = await transport.paths
        #expect(paths.count == 24)
        #expect(paths.prefix(12).allSatisfy { $0.hasPrefix("/hosts/localhost/") })
        #expect(paths.suffix(12).allSatisfy { $0.hasPrefix("/hosts/work%20%2F%20host/") })
        #expect(paths.contains("/hosts/work%20%2F%20host/agents/agent%20%2F%20one/logs?lines=20"))
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

    @Test func hubStreamCapturesHelloAndInitialHostBurst() async throws {
        var script = FakeHubScript()
        script.hosts = [
            .init(name: "localhost", local: true, state: .local),
            .init(name: "work", ssh: "evan@work", state: .connected),
            .init(name: "broken", ssh: "evan@broken", state: .error, error: "Permission denied", code: "ssh_auth_required")
        ]
        let daemon = try FakeHubDaemon(script: script)
        let collector = HubEventCollector()
        let stream = await LeoHubActivityClient(socketPath: daemon.path).events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
                if await collector.count == 4 { return }
            }
        }
        await awaitCondition { await collector.count == 4 }
        task.cancel()
        let events = await collector.events
        let hello = try #require(events.first)
        #expect(hello == .hello(seq: 1, at: nil, version: "0.29.0", serverTime: nil))
        let rows = events.compactMap { if case .hostStateChanged(let row) = $0 { row } else { nil } }
        #expect(rows.map(\.name) == ["localhost", "work", "broken"])
        #expect(rows.last?.code == "ssh_auth_required")
    }

    @Test func hubStreamDeliversFrameBeforeAnotherByteAndReportsServerClose() async throws {
        let daemon = try FakeHubDaemon()
        let collector = HubEventCollector()
        let stream = await LeoHubActivityClient(socketPath: daemon.path).events()
        let task = Task { for await event in stream { await collector.append(event) } }
        await awaitCondition(message: "hello frame was buffered") { await collector.count >= 2 }
        await daemon.controller.close()
        await awaitCondition { await collector.events.contains { if case .disconnected = $0 { true } else { false } } }
        task.cancel()
    }

    @Test func cancellingHubStreamClosesEventSocket() async throws {
        let daemon = try FakeHubDaemon()
        let stream = await LeoHubActivityClient(socketPath: daemon.path).events()
        let task = Task { for await _ in stream {} }
        await awaitCondition { daemon.requests().contains { $0.path == "/events" } }
        task.cancel()
        await awaitCondition(message: "fake did not observe event connection close") {
            await daemon.controller.didObserveEventConnectionClose()
        }
    }
}

private actor HubEventCollector {
    private(set) var events: [LeoObserveEvent] = []
    var count: Int { events.count }
    func append(_ event: LeoObserveEvent) { events.append(event) }
}

private actor HubRecordingTransport: LeoDaemonTransport {
    private(set) var paths: [String] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        paths.append(request.path)
        let data: String
        if request.path.hasSuffix("/agents/list") || request.path.hasSuffix("/templates") {
            data = #"{"ok":true,"data":[]}"#
        } else if request.path.hasSuffix("/delete-plan") {
            data = #"{"ok":true,"data":{"name":"agent","has_worktree":false}}"#
        } else if request.path.contains("/logs") {
            data = #"{"ok":true,"data":{"output":"log"}}"#
        } else if request.path.hasSuffix("/spawn") || request.path.hasSuffix("/restart") || request.path.hasSuffix("/rename") {
            data = #"{"ok":true,"data":{"name":"agent"}}"#
        } else if request.path.hasSuffix("/connect") || request.path.hasSuffix("/disconnect") {
            data = #"{"ok":true,"data":{"name":"work host","local":false,"default":false,"state":"connected"}}"#
        } else {
            data = #"{"ok":true}"#
        }
        return .init(status: 200, body: Data(data.utf8))
    }
}

private struct HubUnavailableTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        .init(status: 503, body: Data(#"{"ok":false,"code":"host_unavailable","error":"offline"}"#.utf8))
    }
}
