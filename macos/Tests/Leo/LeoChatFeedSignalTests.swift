import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// What the sidebar feed hands the chat pane: `chat.*` events as they come,
/// and a resync whenever events may have been lost.
@Suite struct LeoChatFeedSignalTests {
    private static let message = chatMessage("m", at: 1)

    @Test func chatEventsPassThrough() {
        #expect(LeoChatFeedSignal(.chat(seq: 4, .message(Self.message))) == .event(.message(Self.message)))
        #expect(LeoChatFeedSignal(.chat(seq: 5, .updated(Self.message))) == .event(.updated(Self.message)))
    }

    @Test func helloGapAndSnapshotResync() {
        #expect(LeoChatFeedSignal(.hello(seq: 1, at: nil, version: nil, serverTime: nil)) == .resync)
        #expect(LeoChatFeedSignal(.gap(expected: 3, received: 5)) == .resync)
    }

    @Test func otherEventsSayNothing() {
        #expect(LeoChatFeedSignal(.connected) == nil)
        #expect(LeoChatFeedSignal(.other(seq: 2, type: "x")) == nil)
        #expect(LeoChatFeedSignal(.disconnected(reason: "gone")) == nil)
    }
}

/// The control bar's row: the full bar where the daemon offers control,
/// just the chat toggle where it doesn't, nothing without an agent.
@MainActor @Suite struct LeoAgentControlBarContentTests {
    private static let row = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)

    private func availability(_ features: [String]) -> LeoAgentControlAvailability {
        LeoAgentControlAvailability(row: Self.row, features: LeoDaemonFeatures(features), deniedHosts: [], inFlight: nil)
    }

    @Test func withoutControlOnlyTheChatToggleShows() {
        #expect(LeoAgentControlBarContent(row: Self.row, availability: availability([])) == .chatToggleOnly)
        #expect(LeoAgentControlBarContent(row: Self.row, availability: availability(["agent_control"])) == .full)
        #expect(LeoAgentControlBarContent(row: nil, availability: availability(["agent_control"])) == .none)
    }
}
