import Foundation
import Testing

@testable import Ghostty

struct LeoActivityCoalescerTests {
    @Test func firstEventReportsItStartedTheWindow() {
        var coalescer = LeoActivityCoalescer()
        let started = coalescer.add(activity(seq: 1, agent: "alpha", detail: "a"))
        #expect(started)
        #expect(!coalescer.isEmpty)
    }

    @Test func subsequentEventsDoNotReportStartingANewWindow() {
        var coalescer = LeoActivityCoalescer()
        _ = coalescer.add(activity(seq: 1, agent: "alpha", detail: "a"))
        let second = coalescer.add(activity(seq: 2, agent: "alpha", detail: "b"))
        let third = coalescer.add(activity(seq: 3, agent: "bravo", detail: "c"))
        #expect(!second)
        #expect(!third)
    }

    @Test func drainReturnsLastWriteWinsPerAgent() {
        var coalescer = LeoActivityCoalescer()
        _ = coalescer.add(activity(seq: 1, agent: "alpha", detail: "first"))
        _ = coalescer.add(activity(seq: 2, agent: "alpha", detail: "second"))
        _ = coalescer.add(activity(seq: 3, agent: "bravo", detail: "only"))

        let drained = coalescer.drain()

        #expect(drained.count == 2)
        let details = Dictionary(uniqueKeysWithValues: drained.compactMap { event -> (String, String?)? in
            guard case let .agentActivity(_, _, name, _, currentAction, _) = event else { return nil }
            return (name, currentAction?.detail)
        })
        #expect(details["alpha"] == "second")
        #expect(details["bravo"] == "only")
    }

    @Test func drainResetsTheBufferAndTheNextAddStartsANewWindow() {
        var coalescer = LeoActivityCoalescer()
        _ = coalescer.add(activity(seq: 1, agent: "alpha", detail: "a"))
        _ = coalescer.drain()

        #expect(coalescer.isEmpty)
        let started = coalescer.add(activity(seq: 2, agent: "alpha", detail: "b"))
        #expect(started)
    }

    @Test func drainingAnEmptyBufferReturnsNoEvents() {
        var coalescer = LeoActivityCoalescer()
        #expect(coalescer.drain().isEmpty)
    }

    @Test func nonActivityEventsAreIgnoredAndNeverStartAWindow() {
        var coalescer = LeoActivityCoalescer()
        let started = coalescer.add(.hello(seq: 1, at: nil, version: nil, serverTime: nil))
        #expect(!started)
        #expect(coalescer.isEmpty)
        #expect(coalescer.drain().isEmpty)
    }

    private func activity(seq: Int, agent: String, detail: String) -> LeoObserveEvent {
        .agentActivity(seq: seq, at: nil, agent: agent, activity: .working, currentAction: .init(kind: "tool", detail: detail))
    }
}
