import Testing

@testable import Ghostty
@testable import LeoKit

/// B-016: focus updates reach the attention feed in the order they were
/// sent, so a burst like "nil then A" never lands as "A then nil".
struct LeoOrderedRelayTests {
    @Test func deliversEveryValueInTheOrderSent() async {
        let received = Received()
        let relay = LeoOrderedRelay<Int?> { await received.append($0) }
        let sent: [Int?] = (0..<500).map { $0.isMultiple(of: 2) ? nil : $0 }

        for value in sent { relay.send(value) }
        await relay.finish()

        #expect(await received.values == sent)
        #expect(await received.values.last == sent.last, "the feed ends up with the last value sent")
    }

    /// The runtime's tests need "everything sent so far has been handled"
    /// without ending the relay: a late delivery must not land mid-assertion.
    @Test func settledReturnsOnceEverythingAlreadySentHasBeenHandled() async {
        let received = Received()
        let relay = LeoOrderedRelay<Int?> {
            await Task.yield()
            await received.append($0)
        }

        for value in 0..<50 { relay.send(value) }
        await relay.settled()

        #expect(await received.values.count == 50)

        relay.send(50)
        await relay.settled()
        #expect(await received.values.last == 50, "the relay keeps delivering after a settle")
    }

    @Test func settledAfterFinishReturnsInsteadOfWaitingForever() async {
        let relay = LeoOrderedRelay<Int?> { _ in }
        await relay.finish()

        await relay.settled()
    }
}

private actor Received {
    private(set) var values: [Int?] = []
    func append(_ value: Int?) { values.append(value) }
}
