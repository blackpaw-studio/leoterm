import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// How the sidebar's rows become the inbox's agents: the boot a row's
/// signal belongs to must reach the inbox, or a restarted daemon's reused
/// revisions look already seen.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoInboxAgentsTests {
    private static let signal = LeoAttentionSignal(state: .finished, revision: 3)

    private func row(bootID: String?, name: String = "alpha", status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil,
            attentionSignal: Self.signal, attentionBootID: bootID
        )
    }

    @Test func anInboxAgentCarriesTheBootItsRowsSignalBelongsTo() {
        let snapshot = LeoSidebarSnapshot(rows: [row(bootID: "boot-a")], connectivity: .connected, generation: 1)
        #expect(LeoInboxAgents.make(from: [.local: snapshot]).map(\.bootID) == ["boot-a"])
    }

    @Test func aLiveFeedsOverlayStampsRowsWithItsReducersBoot() {
        var reducer = LeoAttentionReducer()
        _ = reducer.observeBoot("boot-a")
        let overlaid = LeoSidebarSnapshot(rows: [row(bootID: nil)], connectivity: .connected, generation: 1).overlayingAttention(reducer)
        #expect(overlaid.rows.map(\.attentionBootID) == ["boot-a"])
    }

    @Test func aDisconnectedFeedsRowsCarryNoBoot() {
        var reducer = LeoAttentionReducer()
        _ = reducer.observeBoot("boot-a")
        let snapshot = LeoSidebarSnapshot(rows: [row(bootID: "boot-a")], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 1)
        #expect(snapshot.overlayingAttention(reducer).rows.map(\.attentionBootID) == [nil])
    }

    @Test func aStoppedRowMapsToAStoppedInboxAgent() {
        let snapshot = LeoSidebarSnapshot(
            rows: [row(bootID: nil, status: .stopped), row(bootID: nil, name: "beta")], connectivity: .connected, generation: 1
        )
        let agents = LeoInboxAgents.make(from: [.local: snapshot])
        #expect(Set(agents.filter(\.isStopped).map(\.name)) == ["alpha"])
        #expect(LeoInbox.derive(agents: agents, openAsks: [:], seen: LeoInboxSeenState()).finished.map(\.agent) == ["beta"])
    }
}
