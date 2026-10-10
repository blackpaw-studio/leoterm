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
        let script = try SteppedDispatchDaemon(trace: try fixture("dispatch_hold_events.sse"), stateBody: Self.stateBody(afterStep:))
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
            onAttentionTransitions: { transitions in recorder.record(transitions) },
            sink: { snapshot in recorder.record(snapshot) }
        )
        await feed.start()
        await feed.setPolling(true)

        // 1: hello + alpha working r1; the baseline lands silently.
        await script.open(step: 1)
        await awaitCondition(timeout: 5, message: "alpha never showed Working") { recorder.alpha?.attention == .working }

        // 2: d1 starts under alpha.
        await script.open(step: 2)
        await awaitCondition(timeout: 5, message: "d1 never nested under alpha") { recorder.alphaChildren == ["d1:0"] }

        // 3: d1's own dispatch d2 nests under d1.
        await script.open(step: 3)
        await awaitCondition(timeout: 5, message: "d2 never nested under d1") { recorder.alphaChildren == ["d1:0", "d2:1"] }

        // 4: alpha's turn ends; the daemon holds it at working r2.
        await script.open(step: 4)
        await awaitCondition(timeout: 5, message: "the turn-end activity never landed") { recorder.alpha?.activity == .idle }
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(recorder.alpha?.attention == .working, "outstanding children hold alpha at Working")
        #expect(recorder.alphaChildren == ["d1:0", "d2:1"])

        // 5: d2 ends; d1 still runs, so alpha is still working.
        await script.open(step: 5)
        await awaitCondition(timeout: 5, message: "d2 never went away") { recorder.alphaChildren == ["d1:0"] }
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(recorder.alpha?.attention == .working)

        // 6: d1 ends, then alpha finishes.
        await script.open(step: 6)
        await awaitCondition(timeout: 5, message: "alpha never finished") { recorder.alpha?.attention == .finished }
        #expect(recorder.alphaChildren.isEmpty)
        try await Task.sleep(nanoseconds: Self.pastCommitWindow)
        #expect(recorder.notifyingTransitions.map(\.to) == [.finished], "exactly one transition notifies")

        // Every recorded snapshot: a live child means Working, never Finished.
        for snapshot in recorder.snapshots {
            guard let alpha = snapshot.rows.first(where: { $0.name == "alpha" }) else { continue }
            if !(snapshot.dispatchChildren["alpha"] ?? []).isEmpty {
                #expect(alpha.attention == .working, "a live child shows \(String(describing: alpha.attention))")
            }
        }
        await feed.stop()
    }

    /// `/state` as the daemon would answer after the `step`th gate.
    private nonisolated static func stateBody(afterStep step: Int) -> String {
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
        return #"{"ok":true,"data":{"agents":[{"name":"alpha","status":"running","activity":"idle","attention":\#(attention)}]\#(dispatchesField)}}"#
    }

    /// The reducer's 300 ms stability window, plus slack for a loaded host.
    private static let pastCommitWindow: UInt64 = 700_000_000

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
    }
}

/// Records on the sink's own call, under a lock, so snapshots keep the
/// feed's emission order (no hop through an unstructured Task).
private final class DispatchHoldRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshots: [LeoSidebarSnapshot] = []
    private var storedTransitions: [LeoAttentionTransition] = []

    func record(_ snapshot: LeoSidebarSnapshot) { lock.withLock { storedSnapshots.append(snapshot) } }
    func record(_ transitions: [LeoAttentionTransition]) { lock.withLock { storedTransitions += transitions } }

    var snapshots: [LeoSidebarSnapshot] { lock.withLock { storedSnapshots } }
    var alpha: LeoAgentRow? { snapshots.last?.rows.first { $0.name == "alpha" } }
    /// `id:depth` for each child under alpha in the latest snapshot.
    var alphaChildren: [String] { (snapshots.last?.dispatchChildren["alpha"] ?? []).map { "\($0.id):\($0.depth)" } }
    var notifyingTransitions: [LeoAttentionTransition] { lock.withLock { storedTransitions.filter(\.shouldNotify) } }
}
