import Testing

@testable import LeoKit

@MainActor
struct LeoBrowserSerialGateTests {
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    @Test func aWaiterCancelledAfterItWasHandedTheTurnNeverRunsAndDoesNotWedgeTheGate() async throws {
        let gate = LeoBrowserSerialGate()
        let latch = Latch()
        var ran: [String] = []
        var second: Task<Void, any Error>?
        let first = Task {
            try await gate.run {
                await latch.wait()
                // Cancel in the same synchronous stretch as the hand-over, so the
                // waiter is resumed already cancelled (the cancel's own queue
                // removal finds nothing left to remove).
                second?.cancel()
                ran.append("a")
            }
        }
        await settle { gate.isBusy }
        second = Task { try await gate.run { ran.append("b") } }
        await settle { gate.waitingCount == 1 }

        latch.open()

        try await first.value
        await #expect(throws: CancellationError.self) { try await second!.value }
        #expect(ran == ["a"])
        try await gate.run { ran.append("c") }
        #expect(ran == ["a", "c"])
    }
}
