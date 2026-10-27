import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AgentAppearanceModelTests {
    private static let teal = LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(1))

    @Test func snapshotSeedsAppearanceAndAbsentMeansNone() {
        var session = DaemonSession(daemon: .dionysus)
        let withLook = LeoObservedAgent(
            name: "zeus", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, appearance: Self.teal
        )
        session.applySnapshot(LeoObservedState(agents: [withLook, .make("hera")]))

        #expect(session.agents[id: "zeus"]?.appearance == Self.teal)
        #expect(session.agents[id: "hera"]?.appearance == nil)
    }

    @Test func appearanceChangedSetsTheWholeValueAndNullClearsIt() {
        var session = DaemonSession(daemon: .dionysus)
        session.applySnapshot(LeoObservedState(agents: [.make("zeus")]))

        session.apply(.agentAppearanceChanged(seq: 2, at: nil, agent: "zeus", appearance: Self.teal))
        #expect(session.agents[id: "zeus"]?.appearance == Self.teal)

        let colorOnly = LeoAgentAppearance(emoji: nil, color: .red, emojiSource: nil, colorSource: .manual)
        session.apply(.agentAppearanceChanged(seq: 3, at: nil, agent: "zeus", appearance: colorOnly))
        #expect(session.agents[id: "zeus"]?.appearance == colorOnly)

        session.apply(.agentAppearanceChanged(seq: 4, at: nil, agent: "zeus", appearance: nil))
        #expect(session.agents[id: "zeus"]?.appearance == nil)
    }

    @Test func appearanceChangedForAnUnknownAgentIsIgnored() {
        var session = DaemonSession(daemon: .dionysus)
        session.apply(.agentAppearanceChanged(seq: 2, at: nil, agent: "ghost", appearance: Self.teal))
        #expect(session.agents.isEmpty)
    }

    @Test func aNewSnapshotRestatesAppearance() {
        var session = DaemonSession(daemon: .dionysus)
        session.applySnapshot(LeoObservedState(agents: [.make("zeus")]))
        session.apply(.agentAppearanceChanged(seq: 2, at: nil, agent: "zeus", appearance: Self.teal))

        session.applySnapshot(LeoObservedState(agents: [.make("zeus")]))
        #expect(session.agents[id: "zeus"]?.appearance == nil)
    }
}
