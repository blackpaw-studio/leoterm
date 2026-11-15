import Testing

@testable import LeoKit

struct LeoSpawnMachineDefaultTests {
    private let work = LeoHostID.remote("work")
    private let lab = LeoHostID.remote("lab")

    private func resolve(
        context: LeoHostID? = nil, lastUsed: LeoHostID? = nil, _ statuses: [LeoHostID: LeoMachineStatus]
    ) -> LeoHostID {
        LeoSpawnMachineDefault.resolve(context: context, lastUsed: lastUsed, statuses: statuses)
    }

    @Test func prefersAReachableContextMachine() {
        let statuses: [LeoHostID: LeoMachineStatus] = [.local: .connected, work: .connected, lab: .connected]
        #expect(resolve(context: work, lastUsed: lab, statuses) == work)
    }

    @Test func unreachableContextFallsThroughToLastUsed() {
        let statuses: [LeoHostID: LeoMachineStatus] = [.local: .connected, work: .failed("timeout"), lab: .connected]
        #expect(resolve(context: work, lastUsed: lab, statuses) == lab)
    }

    @Test func connectingAndDisabledMachinesAreSkipped() {
        let statuses: [LeoHostID: LeoMachineStatus] = [.local: .connected, work: .connecting, lab: .disabled]
        #expect(resolve(context: work, lastUsed: lab, statuses) == .local)
    }

    @Test func removedLastUsedMachineGivesLocal() {
        #expect(resolve(lastUsed: work, [.local: .connected]) == .local)
    }

    @Test func noContextAndNoHistoryGivesLocal() {
        #expect(resolve([.local: .connected, work: .connected]) == .local)
    }

    @Test func localIsTheFallbackEvenWhenItHasNoStatus() {
        #expect(resolve(context: work, [work: .failed("x")]) == .local)
    }
}
