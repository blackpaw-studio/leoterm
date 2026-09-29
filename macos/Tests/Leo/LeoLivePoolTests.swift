import Testing

@testable import Ghostty

/// B-056: the pure live-pool policy (D-108). Entries are strings here; the
/// host's are whole surface trees.
struct LeoLivePoolTests {
    private let one: (String) -> Int = { _ in 1 }

    @Test func theCapacityIsFourClientsPerWindow() {
        #expect(LeoLivePoolCapacity.perWindow == 4)
        #expect(LeoLivePool<String>().capacity == 4)
    }

    @Test func hidingAppendsAsTheMostRecentlyViewed() {
        let pool = LeoLivePool<String>().hiding("a").hiding("b")

        #expect(pool.entries == ["a", "b"])
    }

    @Test func threeHiddenPlusTheShownOneFit() {
        let pool = LeoLivePool<String>().hiding("a").hiding("b").hiding("c")

        let (trimmed, evicted) = pool.trimmed(shownClients: 1, clients: one)

        #expect(trimmed.entries == ["a", "b", "c"])
        #expect(evicted.isEmpty)
    }

    @Test func aFifthAgentEvictsTheLeastRecentlyViewed() {
        let pool = LeoLivePool<String>().hiding("a").hiding("b").hiding("c").hiding("d")

        let (trimmed, evicted) = pool.trimmed(shownClients: 1, clients: one)

        #expect(evicted == ["a"])
        #expect(trimmed.entries == ["b", "c", "d"])
    }

    @Test func aSplitWeighsItsClients() {
        let weights = ["a": 1, "split": 2, "c": 1]
        let pool = LeoLivePool<String>(entries: ["a", "split", "c"])

        let (trimmed, evicted) = pool.trimmed(shownClients: 2) { weights[$0] ?? 0 }

        #expect(evicted == ["a", "split"], "least recent first until 2 shown + hidden <= 4")
        #expect(trimmed.entries == ["c"])
    }

    @Test func entriesWithNoLiveClientAreDropped() {
        let pool = LeoLivePool<String>(entries: ["dead", "live"])

        let (trimmed, evicted) = pool.trimmed(shownClients: 1) { $0 == "dead" ? 0 : 1 }

        #expect(evicted == ["dead"])
        #expect(trimmed.entries == ["live"])
    }

    @Test func aShownContentOverCapacityEmptiesThePool() {
        let pool = LeoLivePool<String>(entries: ["a", "b"])

        let (trimmed, evicted) = pool.trimmed(shownClients: 5, clients: one)

        #expect(trimmed.entries.isEmpty)
        #expect(evicted == ["a", "b"])
    }

    @Test func aPlainShellShownLeavesRoomForFourHidden() {
        let pool = LeoLivePool<String>(entries: ["a", "b", "c", "d"])

        let (trimmed, evicted) = pool.trimmed(shownClients: 0, clients: one)

        #expect(evicted.isEmpty)
        #expect(trimmed.entries.count == 4)
    }

    @Test func takingRemovesTheMatchingEntry() {
        let pool = LeoLivePool<String>(entries: ["a", "b", "c"])

        let (remaining, taken) = pool.taking { $0 == "b" }

        #expect(taken == "b")
        #expect(remaining.entries == ["a", "c"])
    }

    @Test func takingNothingLeavesThePoolAlone() {
        let pool = LeoLivePool<String>(entries: ["a"])

        let (remaining, taken) = pool.taking { $0 == "z" }

        #expect(taken == nil)
        #expect(remaining.entries == ["a"])
    }

    @Test func removingReturnsWhatWasLetGo() {
        let pool = LeoLivePool<String>(entries: ["a", "b", "a2"])

        let (remaining, removed) = pool.removing { $0.hasPrefix("a") }

        #expect(removed == ["a", "a2"])
        #expect(remaining.entries == ["b"])
    }

    @Test func aCustomCapacityIsKept() {
        let pool = LeoLivePool<String>(capacity: 2).hiding("a").hiding("b")

        let (trimmed, evicted) = pool.trimmed(shownClients: 1, clients: one)

        #expect(trimmed.capacity == 2)
        #expect(evicted == ["a"])
    }
}
