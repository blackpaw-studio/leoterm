import Foundation
import Testing

@testable import LeoKit

struct LeoActivityClientAgentSeenTests {
    private func decode(_ json: String) -> LeoObserveEvent? {
        LeoActivityClient.decode(LeoSSEEvent(name: "agent_seen", data: json, id: nil))
    }

    @Test func agentSeenDecodesAgentAndTime() {
        let event = decode(#"{"seq":9,"agent":"zeus","seen_at":"2026-11-24T17:00:00Z"}"#)
        #expect(event == .agentSeen(seq: 9, agent: "zeus", seenAt: Date(timeIntervalSince1970: 1_795_539_600)))
        #expect(event?.sequence == 9)
    }

    @Test func aMalformedAgentSeenOnlyAdvancesTheSequence() {
        #expect(decode(#"{"seq":9,"agent":"zeus","seen_at":"soon"}"#) == .other(seq: 9, type: "agent_seen"))
        #expect(decode(#"{"seq":9,"seen_at":"2026-11-24T17:00:00Z"}"#) == .other(seq: 9, type: "agent_seen"))
    }
}
