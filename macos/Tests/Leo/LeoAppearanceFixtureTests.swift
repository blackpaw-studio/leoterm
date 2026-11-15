#if DEBUG
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The fixture file's `appearance` key advertises the feature and overlays
/// named agents' appearance on `/state`, read by the wire's own decoder.
struct LeoAppearanceFixtureTests {
    private static let json = #"""
    {"appearance": {
      "autopilot-scratch": {"emoji": "🏛️", "color": "teal", "emoji_source": "manual", "color_source": "rule:0"},
      "color-only": {"color": "purple"},
      "junk": {"color": "chartreuse"}
    }}
    """#

    @Test func appearanceKeyAdvertisesAndOverlays() async throws {
        let fixture = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(Self.json.utf8))
        #expect(fixture.appearance["autopilot-scratch"] == LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)))
        #expect(fixture.appearance["color-only"] == LeoAgentAppearance(emoji: nil, color: .purple))
        #expect(fixture.appearance["junk"] == nil, "an unknown color alone reads as no appearance")

        let (stream, continuation) = AsyncStream<LeoObserveEvent>.makeStream()
        continuation.yield(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b", features: []))
        continuation.finish()
        var seen: [LeoObserveEvent] = []
        for await event in LeoAttentionFixture.advertising(stream, usage: false, turns: [:], appearance: true) { seen.append(event) }
        guard case .hello(_, _, _, _, _, let features) = seen.first else { Issue.record("no hello"); return }
        #expect(features == ["agent_appearance"])

        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: ["autopilot-scratch", "other"].map {
                LeoObservedAgent(name: $0, status: .running, activity: nil, currentAction: nil, lastActivityAt: nil)
            })
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: [:], appearance: fixture.appearance).fetchState()
        #expect(state.agents.map(\.appearance) == [fixture.appearance["autopilot-scratch"], nil])
    }
}
#endif
