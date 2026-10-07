import Foundation
import Testing

@testable import Ghostty

/// B-261: `agent_compaction` decodes into its own event, and a malformed
/// one still advances the sequence.
struct LeoCompactionDecodingTests {
    private func decode(_ json: String) -> LeoObserveEvent? {
        LeoActivityClient.decode(LeoSSEEvent(name: "agent_compaction", data: json, id: nil))
    }

    @Test func decodesCompactionStarted() {
        let event = decode(#"{"seq":7,"agent":"alpha","phase":"started","trigger":"auto","context_percent":91.5}"#)
        let expected = LeoCompactionEvent(agent: "alpha", phase: .started, trigger: .auto, contextPercent: 91.5)
        #expect(event == .agentCompaction(seq: 7, compaction: expected))
    }

    @Test func decodesCompactionCompletedAndFailed() {
        let completed = decode(#"{"seq":8,"agent":"alpha","phase":"completed","trigger":"manual"}"#)
        let failed = decode(#"{"seq":9,"agent":"alpha","phase":"failed"}"#)
        #expect(completed == .agentCompaction(seq: 8, compaction: LeoCompactionEvent(agent: "alpha", phase: .completed, trigger: .manual, contextPercent: nil)))
        #expect(failed == .agentCompaction(seq: 9, compaction: LeoCompactionEvent(agent: "alpha", phase: .failed, trigger: nil, contextPercent: nil)))
    }

    @Test func anUnknownTriggerReadsAsNoTrigger() {
        let event = decode(#"{"seq":10,"agent":"alpha","phase":"started","trigger":"cosmic"}"#)
        #expect(event == .agentCompaction(seq: 10, compaction: LeoCompactionEvent(agent: "alpha", phase: .started, trigger: nil, contextPercent: nil)))
    }

    @Test func malformedCompactionKeepsSequence() {
        #expect(decode(#"{"seq":11,"phase":"started"}"#) == .other(seq: 11, type: "agent_compaction"))
        #expect(decode(#"{"seq":12,"agent":"alpha","phase":"sideways"}"#) == .other(seq: 12, type: "agent_compaction"))
    }
}
