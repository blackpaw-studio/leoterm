#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// The DEBUG-only `LEO_ATTENTION_FIXTURE` overlay used to screenshot
/// attention badges before the daemon emits `attention`.
struct LeoAttentionFixtureTests {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/attention_overlay.json").path
    }

    @Test func loadsTheOverlayNamedByTheEnvironment() throws {
        let overlay = try #require(LeoAttentionFixture.load(environment: [LeoAttentionFixture.environmentKey: fixturePath]))
        #expect(overlay["alpha"] == LeoAttentionSignal(state: .needsInput, revision: 1))
        #expect(overlay.count == 4)
    }

    /// B-257: a reserved `dispatches` key adds dispatches to `/state`, so
    /// nested rows can be screenshotted; the other keys stay attention.
    @Test func aDispatchesKeyOverlaysDispatchesOnState() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dispatch_overlay.json").path
        let file = try #require(LeoAttentionFixture.loadFile(environment: [LeoAttentionFixture.environmentKey: path]))
        #expect(file.attention == ["autopilot-scratch": LeoAttentionSignal(state: .working, revision: 1)])
        #expect(file.dispatches.map(\.id) == ["fx-1", "fx-2", "fx-3"])

        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: [], dispatches: [LeoDispatch(id: "real", status: "running"), LeoDispatch(id: "fx-1", status: "queued")])
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention, dispatches: file.dispatches).fetchState()
        #expect(state.dispatches.map(\.id) == ["real", "fx-1", "fx-2", "fx-3"])
        #expect(state.dispatches.first { $0.id == "fx-1" }?.status == "running", "the fixture's record wins")
    }

    @Test func fixtureEntryDecodesItsReason() async throws {
        let json = #"{"alpha":{"state":"needs_input","revision":1,"reason":{"kind":"permission","tool":"Bash"}},"beta":{"state":"needs_input","revision":1}}"#
        let file = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(json.utf8))
        #expect(file.attention["alpha"]?.reason == LeoAttentionReason(kind: .permission, tool: "Bash"))
        #expect(file.attention["beta"]?.reason == nil)
        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: [LeoObservedAgent(name: "alpha", status: nil, activity: nil, currentAction: nil, lastActivityAt: nil, attention: nil)], dispatches: [])
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention).fetchState()
        #expect(state.agents.first?.attention?.reason?.tool == "Bash")
    }

    @Test func noEnvironmentOrUnreadableFileMeansNoOverlay() {
        #expect(LeoAttentionFixture.load(environment: [:]) == nil)
        #expect(LeoAttentionFixture.load(environment: [LeoAttentionFixture.environmentKey: "/nonexistent.json"]) == nil)
    }

    @Test func overlayReplacesAttentionOnlyForNamedAgents() async throws {
        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: {
            [
                LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil),
                LeoObservedAgent(name: "other", status: .running, activity: .working, currentAction: nil, lastActivityAt: nil)
            ]
        })
        let wrapped = LeoAttentionFixture.wrap(base, overlay: ["alpha": .init(state: .finished, revision: 3)])

        let agents = try await wrapped.fetchState().agents

        #expect(agents.map(\.attention) == [.init(state: .finished, revision: 3), nil])
        #expect(agents.map(\.activity) == [.idle, .working])
    }
}
#endif
