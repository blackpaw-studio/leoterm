import Darwin
import Foundation
import Testing

@testable import Ghostty

/// End to end over a real unix socket: a scripted fake daemon serves
/// `/events` + `/state` with `attention`, through `LeoSocketActivityClient`,
/// `LeoSidebarFeed`'s reducer and `LeoAttentionController`. Two agents: the
/// focused one is suppressed, the background one notifies exactly once,
/// Jump targets it, and a Retry after the stream drops replays the same
/// revisions and posts nothing new.
@MainActor struct LeoAttentionIntegrationTests {
    private static let alpha = LeoAgentRow.ID(host: .local, name: "alpha")
    private static let beta = LeoAgentRow.ID(host: .local, name: "beta")

    @Test func focusedSuppressionOneBackgroundNotificationJumpAndReconnectWithoutDuplicates() async throws {
        let script = FakeAttentionDaemon()
        let server = try ConcurrentUnixSocketServer { client in script.serve(client) }
        defer { server.stop() }
        let client = LeoSocketActivityClient(socketPath: server.path)
        let center = RecordingNotificationCenter()
        let defaults = LeoInMemoryDefaults()
        let controller = LeoAttentionController(center: center, defaults: defaults, currentHost: { .local }, showDeniedInstructions: {})
        await controller.enable()
        let snapshots = SnapshotBox()
        let daemon = ListOnlyDaemon(names: ["alpha", "beta"])
        let source = LeoSidebarActivitySource(events: { await client.events() }, observedState: { try await client.fetchState() })
        let feed = LeoSidebarFeed(
            daemon: daemon,
            activity: source,
            onAttentionTransitions: { transitions in Task { await controller.handle(transitions) } },
            sink: { snapshot in Task { await snapshots.set(snapshot) } }
        )

        await feed.start()
        await feed.setPolling(true)
        await feed.setFocusedAgent(Self.alpha)

        await awaitCondition(timeout: 5, message: "live attention never committed") {
            let rows = await snapshots.value?.rows ?? []
            return rows.first { $0.name == "alpha" }?.attention == .needsInput
                && rows.first { $0.name == "beta" }?.attention == .finished
        }
        await awaitCondition { await center.titles.count == 1 }
        #expect(center.titles == ["beta · localhost"], "the focused agent is suppressed")
        let snapshot = try #require(await snapshots.value)
        #expect(snapshot.attentionCount == 1, "focus acknowledged alpha")

        let rows = LeoSidebarReducers.rank(snapshot.rows)
        let target = LeoAttentionNavigation.next(
            in: rows.map(\.id), needing: LeoAttentionNavigation.needing(rows), focused: Self.alpha, selected: nil
        )
        #expect(target == Self.beta)

        // The first stream closes: the feed waits, disconnected, for Retry
        // (D-061) -- which reconnects the same host.
        await awaitCondition(timeout: 5, message: "the dropped stream never disconnected") {
            if case .disconnected = await snapshots.value?.connectivity { return true }
            return false
        }
        #expect(script.eventsConnections == 1, "no automatic reconnect")
        await feed.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemon, activitySource: source))

        await awaitCondition(timeout: 5, message: "client never reconnected") { script.eventsConnections >= 2 && script.replayed }
        await awaitCondition(timeout: 2) { await snapshots.value?.rows.first { $0.name == "beta" }?.attention == .finished }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(center.titles == ["beta · localhost"], "a reconnect replaying revisions never re-notifies")
        await feed.stop()
    }
}

private actor SnapshotBox {
    private(set) var value: LeoSidebarSnapshot?
    func set(_ snapshot: LeoSidebarSnapshot) { value = snapshot }
}

@MainActor private final class RecordingNotificationCenter: LeoNotificationPosting {
    private(set) var titles: [String] = []
    func requestAlertAuthorization() async -> Bool { true }
    func post(_ notification: LeoAttentionNotification) async { titles.append(notification.title) }
}

/// Serves `GET /state` and `GET /events` like a leo daemon that emits
/// `attention`. Every `/events` connection sends `hello`, waits for the
/// app's silent baseline, then alpha → needs_input r2 and beta → finished
/// r2; the first connection closes after the commit window (the app then
/// waits for Retry), the second replays the same revisions.
private final class FakeAttentionDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var eventsSent = false
    private var didReplay = false

    var eventsConnections: Int { lock.withLock { connections } }
    var replayed: Bool { lock.withLock { didReplay } }

    func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        let request = String(bytes: buffer.prefix(max(0, count)), encoding: .utf8) ?? ""
        if request.hasPrefix("GET /state") {
            respondWithState(client)
        } else if request.hasPrefix("GET /events") {
            streamEvents(client)
        }
    }

    private func respondWithState(_ client: Int32) {
        let sent = lock.withLock { eventsSent }
        let alpha = sent ? #"{"state":"needs_input","revision":2}"# : #"{"state":"working","revision":1}"#
        let beta = sent ? #"{"state":"finished","revision":2}"# : #"{"state":"working","revision":1}"#
        let body = #"{"ok":true,"data":{"agents":[{"name":"alpha","status":"running","activity":"idle","attention":\#(alpha)},"#
            + #"{"name":"beta","status":"running","activity":"idle","attention":\#(beta)}]}}"#
        write(client, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        _ = Darwin.shutdown(client, SHUT_WR)
    }

    private func streamEvents(_ client: Int32) {
        let connection = lock.withLock { connections += 1; return connections }
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
        write(client, "event: hello\ndata: {\"seq\":1,\"version\":1}\n\n")
        guard connection <= 2 else {
            Thread.sleep(forTimeInterval: 1)
            return
        }
        Thread.sleep(forTimeInterval: 0.4)
        write(client, """
        event: agent_activity
        data: {"seq":2,"agent":"alpha","activity":"idle","attention":{"state":"needs_input","revision":2}}

        event: agent_activity
        data: {"seq":3,"agent":"beta","activity":"idle","attention":{"state":"finished","revision":2}}


        """)
        lock.withLock {
            eventsSent = true
            if connection == 2 { didReplay = true }
        }
        Thread.sleep(forTimeInterval: connection == 1 ? 0.8 : 1)
    }

    private func write(_ client: Int32, _ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, data.count, 0) }
    }
}

private actor ListOnlyDaemon: LeoDaemonClient {
    private let names: [String]
    init(names: [String]) { self.names = names }
    func listAgents() async throws -> [LeoAgent] {
        names.map {
            LeoAgent(name: $0, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
        }
    }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
