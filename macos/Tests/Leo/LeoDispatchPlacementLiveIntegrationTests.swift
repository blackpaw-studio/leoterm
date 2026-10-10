import Foundation
import Testing

@testable import Ghostty

/// B-272 end to end over a real unix socket: a fake leo 0.42 daemon replays
/// `dispatch_placement_live_events.sse` one gate at a time through the
/// socket client, the sidebar feed and the sidebar model. Dispatch d1 under
/// alpha starts in the background, moves into alpha's session when a client
/// attaches, and moves back when it detaches. At every step alpha has
/// exactly one d1 row, and a click goes to where the viewer now lives.
@MainActor struct LeoDispatchPlacementLiveIntegrationTests {
    private let d1 = LeoDispatchRef(host: .local, id: "d1")

    @Test func aViewerMovingBackgroundVisibleBackgroundKeepsOneRowAndFollowsIt() async throws {
        let fetches = FetchCounter()
        let script = try SteppedDispatchDaemon(trace: try fixture("dispatch_placement_live_events.sse")) { step in
            fetches.next()
            return Self.stateBody(afterStep: step)
        }
        let server = try ConcurrentUnixSocketServer { client in script.serve(client) }
        defer {
            script.finish()
            server.stop()
        }
        let client = LeoSocketActivityClient(socketPath: server.path)
        let recorder = PlacementRecorder()
        let source = LeoSidebarActivitySource(events: { await client.events() }, observedState: { try await client.fetchState() })
        let feed = LeoSidebarFeed(daemon: HoldListDaemon(), activity: source, sink: { snapshot in recorder.record(snapshot) })
        await feed.start()
        await feed.setPolling(true)

        // 1: hello + alpha working; no dispatch yet.
        await script.open(step: 1)
        await awaitCondition(timeout: 5, message: "alpha never showed up") { recorder.latest?.rows.first?.name == "alpha" }
        let model = LeoSidebarModel(snapshot: try #require(recorder.latest))
        var focuses: [String] = []
        var attaches: [String?] = []
        model.dispatchPaneFocusRequested = { _, pane, _ in focuses.append(pane) }
        model.dispatchAttachRequested = { identity, _, _ in attaches.append(identity.dispatchID) }
        model.attachRequested = { _, _, _ in }
        func follow() throws { model.receive(try #require(recorder.latest)) }

        // 2: d1 starts in the background: attachable, so selectable.
        await script.open(step: 2)
        await awaitCondition(timeout: 5, message: "d1 never showed up") { recorder.d1?.attachable == true }
        try follow()
        #expect(recorder.d1Rows == 1)
        #expect(model.isDispatchSelectable(try #require(recorder.d1)))
        #expect(model.callerPaneTarget(d1) == nil)
        model.dispatchClicked(d1, from: LeoWindowID())
        #expect(attaches == ["d1"])
        #expect(focuses.isEmpty)

        // 3: it moves into alpha's session: the same row, now a pane click.
        await script.open(step: 3)
        await awaitCondition(timeout: 5, message: "d1 never moved") { recorder.d1?.attachable == false }
        try follow()
        #expect(recorder.d1Rows == 1, "no duplicate row")
        let visible = try #require(recorder.d1)
        #expect(!model.isDispatchSelectable(visible))
        #expect(model.isDispatchClickable(visible))
        #expect(model.callerPaneTarget(d1)?.pane == "%41")
        model.dispatchClicked(d1, from: LeoWindowID())
        #expect(focuses == ["%41"])
        #expect(attaches == ["d1"], "no attach for a viewer in the caller's session")

        // 4: a re-fetched /state still says background, but at an older seq:
        // the move stands.
        let before = fetches.count
        await script.open(step: 4)
        await awaitCondition(timeout: 5, message: "/state was never re-fetched") { fetches.count > before }
        try await Task.sleep(nanoseconds: Self.settle)
        try follow()
        #expect(recorder.d1Rows == 1)
        #expect(recorder.d1?.attachable == false, "an older baseline does not undo the move")

        // 5: it moves back: selectable again, a click attaches.
        await script.open(step: 5)
        await awaitCondition(timeout: 5, message: "d1 never moved back") { recorder.d1?.attachable == true }
        try follow()
        #expect(recorder.d1Rows == 1)
        #expect(model.isDispatchSelectable(try #require(recorder.d1)))
        #expect(model.callerPaneTarget(d1) == nil)
        model.dispatchClicked(d1, from: LeoWindowID())
        #expect(attaches == ["d1", "d1"])
        #expect(focuses == ["%41"])
        await feed.stop()
    }

    /// Slack for a re-fetched baseline to land after its request was seen.
    private static let settle: UInt64 = 300_000_000

    /// `/state` after the `step`th gate; the fetch after step 4 answers
    /// from before the move (`meta.seq` 3 < the move's 4).
    private nonisolated static func stateBody(afterStep step: Int) -> String {
        let (seq, attachable): (Int, Bool) = switch step {
        case ..<2: (2, true)
        case 2: (3, true)
        case 3: (4, false)
        case 4: (3, true)
        default: (7, true)
        }
        let d1 = step >= 2
            ? #","dispatches":[{"id":"d1","name":"fixer","caller_agent":"alpha","started_at":"2026-10-09T12:00:02Z","stalled":false,"status":"running","attachable":\#(attachable),"tmux_target":"%41"}]"#
            : ""
        return #"{"ok":true,"data":{"agents":[{"name":"alpha","status":"running","activity":"working","attention":{"state":"working","revision":1}}]\#(d1),"meta":{"seq":\#(seq)}}}"#
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0

    var count: Int { lock.withLock { fetches } }

    @discardableResult
    func next() -> Int { lock.withLock { fetches += 1; return fetches } }
}

private final class PlacementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [LeoSidebarSnapshot] = []

    func record(_ snapshot: LeoSidebarSnapshot) { lock.withLock { snapshots.append(snapshot) } }

    var latest: LeoSidebarSnapshot? { lock.withLock { snapshots.last } }
    private var alphaChildren: [LeoDispatchNode] { latest?.dispatchChildren["alpha"] ?? [] }
    var d1: LeoDispatch? { alphaChildren.first { $0.id == "d1" }?.dispatch }
    var d1Rows: Int { alphaChildren.filter { $0.id == "d1" }.count }
}
