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

        let agents = try await wrapped.fetchState()

        #expect(agents.map(\.attention) == [.init(state: .finished, revision: 3), nil])
        #expect(agents.map(\.activity) == [.idle, .working])
    }
}
#endif
