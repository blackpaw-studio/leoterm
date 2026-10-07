import Darwin
import Foundation
import Testing

@testable import Ghostty

/// B-257 end to end over a real unix socket: a fake daemon replays
/// `dispatch_hold_events.sse` one gate at a time through
/// `LeoSocketActivityClient`, `LeoSidebarFeed`, the attention reducer and
/// a recording sink. Alpha's turn ends while its dispatch d1 (and d1's own
/// d2) still run: alpha must stay Working until the last child ends, the
/// children must appear and disappear live, nested by
/// `parent_dispatch_id`, and only the final Finished may notify.
@MainActor struct LeoDispatchHoldIntegrationTests {
    @Test func parentStaysWorkingUntilChildFinishes() async throws {
        let script = try SteppedDispatchDaemon(trace: try fixture("dispatch_hold_events.sse"))
        let server = try ConcurrentUnixSocketServer { client in script.serve(client) }
        defer {
            script.finish()
            server.stop()
        }
        let client = LeoSocketActivityClient(socketPath: server.path)
        let recorder = DispatchHoldRecorder()
        let source = LeoSidebarActivitySource(events: { await client.events() }, observedState: { try await client.fetchState() })
        let feed = LeoSidebarFeed(
            daemon: HoldListDaemon(),
            activity: source,
            onAttentionTransitions: { transitions in Task { await recorder.record(transitions) } },
            sink: { snapshot in Task { await recorder.record(snapshot) } }
        )
        await feed.start()
        await feed.setPolling(true)

        // 1: hello + alpha working r1; the baseline lands silently.
        await script.open(step: 1)
        await awaitCondition(timeout: 5, message: "alpha never showed Working") { await recorder.alpha?.attention == .working }

        // 2: d1 starts under alpha.
        await script.open(step: 2)
        await awaitCondition(timeout: 5, message: "d1 never nested under alpha") { await recorder.alphaChildren == ["d1:0"] }

        // 3: d1's own dispatch d2 nests under d1.
        await script.open(step: 3)
        await awaitCondition(timeout: 5, message: "d2 never nested under d1") { await recorder.alphaChildren == ["d1:0", "d2:1"] }

        // 4: alpha's turn ends; the daemon holds it at working r2.
        await script.open(step: 4)
        await awaitCondition(timeout: 5, message: "the turn-end activity never landed") { await recorder.alpha?.activity == .idle }
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(await recorder.alpha?.attention == .working, "outstanding children hold alpha at Working")
        #expect(await recorder.alphaChildren == ["d1:0", "d2:1"])

        // 5: d2 ends; d1 still runs, so alpha is still working.
        await script.open(step: 5)
        await awaitCondition(timeout: 5, message: "d2 never went away") { await recorder.alphaChildren == ["d1:0"] }
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(await recorder.alpha?.attention == .working)

        // 6: d1 ends, then alpha finishes.
        await script.open(step: 6)
        await awaitCondition(timeout: 5, message: "alpha never finished") { await recorder.alpha?.attention == .finished }
        #expect(await recorder.alphaChildren.isEmpty)
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(await recorder.notifyingTransitions.map(\.to) == [.finished], "exactly one transition notifies")

        // Every recorded snapshot: a live child means Working, never Finished.
        for snapshot in await recorder.snapshots {
            guard let alpha = snapshot.rows.first(where: { $0.name == "alpha" }) else { continue }
            if !(snapshot.dispatchChildren["alpha"] ?? []).isEmpty {
                #expect(alpha.attention == .working, "a live child shows \(String(describing: alpha.attention))")
            }
        }
        await feed.stop()
    }

    /// The reducer's 300 ms stability window, plus slack for a loaded host.
    private static let pastCommitWindow: UInt64 = 700_000_000

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
    }
}

private actor DispatchHoldRecorder {
    private(set) var snapshots: [LeoSidebarSnapshot] = []
    private(set) var transitions: [LeoAttentionTransition] = []

    func record(_ snapshot: LeoSidebarSnapshot) { snapshots.append(snapshot) }
    func record(_ transitions: [LeoAttentionTransition]) { self.transitions += transitions }

    var alpha: LeoAgentRow? { snapshots.last?.rows.first { $0.name == "alpha" } }
    /// `id:depth` for each child under alpha in the latest snapshot.
    var alphaChildren: [String] { (snapshots.last?.dispatchChildren["alpha"] ?? []).map { "\($0.id):\($0.depth)" } }
    var notifyingTransitions: [LeoAttentionTransition] { transitions.filter(\.shouldNotify) }
}

/// Serves `GET /state` and one `GET /events` stream like a leo 0.35
/// daemon. The trace's `: step N` comments split it into gates; `open`
/// sends one gate's events and waits until they're written. `/state`
/// answers with the agents and dispatches as of the last opened gate
/// (ended dispatches linger with their terminal status, as the daemon's
/// 60 s window keeps them).
private final class SteppedDispatchDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [Int: String]
    private var opened = 0
    private var written = 0
    private var finished = false
    private let gate = DispatchSemaphore(value: 0)

    init(trace: String) throws {
        var steps: [Int: String] = [:]
        var current: Int?
        for line in trace.components(separatedBy: "\n") {
            if line.hasPrefix(": step "), let step = Int(line.dropFirst(": step ".count)) {
                current = step
                continue
            }
            guard let current else { continue }
            steps[current, default: ""] += line + "\n"
        }
        self.steps = steps
    }

    func open(step: Int) async {
        lock.withLock { opened = step }
        gate.signal()
        await awaitCondition(timeout: 5, message: "step \(step) was never written") { self.lock.withLock { self.written >= step } }
    }

    func finish() {
        lock.withLock { finished = true }
        gate.signal()
    }

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
        let step = lock.withLock { written }
        let attention = switch step {
        case ..<4: #"{"state":"working","revision":1}"#
        case 4, 5: #"{"state":"working","revision":2,"outstanding":{"dispatches":2,"subagents":0}}"#
        default: #"{"state":"finished","revision":3}"#
        }
        let d1Status = step >= 6 ? #""status":"done","ended_at":"2026-10-06T12:00:06Z""# : #""status":"running""#
        let d2Status = step >= 5 ? #""status":"done","ended_at":"2026-10-06T12:00:05Z""# : #""status":"running""#
        var dispatches: [String] = []
        if step >= 2 { dispatches.append(#"{"id":"d1","name":"fixer","caller_agent":"alpha","started_at":"2026-10-06T12:00:02Z","stalled":false,\#(d1Status)}"#) }
        if step >= 3 {
            dispatches.append(#"{"id":"d2","name":"scout","caller_agent":"fixer","parent_dispatch_id":"d1","started_at":"2026-10-06T12:00:03Z","stalled":false,\#(d2Status)}"#)
        }
        let dispatchesField = dispatches.isEmpty ? "" : #","dispatches":[\#(dispatches.joined(separator: ","))]"#
        let body = #"{"ok":true,"data":{"agents":[{"name":"alpha","status":"running","activity":"idle","attention":\#(attention)}]\#(dispatchesField)}}"#
        write(client, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        _ = Darwin.shutdown(client, SHUT_WR)
    }

    private func streamEvents(_ client: Int32) {
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
        while true {
            gate.wait()
            let (step, done) = lock.withLock { (opened, finished) }
            if done { return }
            guard let chunk = steps[step] else { continue }
            write(client, chunk + "\n")
            lock.withLock { written = step }
        }
    }

    private func write(_ client: Int32, _ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, data.count, 0) }
    }
}

private actor HoldListDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] {
        [LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)]
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
