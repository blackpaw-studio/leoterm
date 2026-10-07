import Testing

@testable import Ghostty

/// B-261: the per-incarnation "compacting" store.
struct LeoCompactionsTests {
    private func row(_ name: String = "alpha", startedAt: String? = "t1") -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil, startedAt: startedAt)
    }

    private func started(_ trigger: LeoCompactionTrigger? = .auto) -> LeoCompactionEvent {
        LeoCompactionEvent(agent: "alpha", phase: .started, trigger: trigger, contextPercent: nil)
    }

    @Test func startedMarksTheMatchingIncarnation() {
        let store = LeoCompactions.empty.recording(started(.manual), startedAt: "t1")
        #expect(store.attach(to: [row()]).first?.compaction == LeoRowCompaction(trigger: .manual))
    }

    @Test func endClears() {
        let store = LeoCompactions.empty.recording(started(), startedAt: "t1").ending("alpha")
        #expect(store.attach(to: [row()]).first?.compaction == nil)
    }

    @Test func otherIncarnationNeverInheritsCompaction() {
        let store = LeoCompactions.empty.recording(started(), startedAt: "t1")
        #expect(store.attach(to: [row(startedAt: "t2"), row(startedAt: nil)]).allSatisfy { $0.compaction == nil })
    }

    @Test func bootChangeDropsCompactions() {
        let store = LeoCompactions.empty.observingBoot("a").recording(started(), startedAt: "t1")
        #expect(store.observingBoot("a").attach(to: [row()]).first?.compaction != nil)
        #expect(store.observingBoot("b").attach(to: [row()]).first?.compaction == nil)
    }

    @Test func attachingClearsRowsWithoutAnEntry() {
        #expect(LeoCompactions.empty.attach(to: [row("beta")]).first?.compaction == nil)
    }
}
