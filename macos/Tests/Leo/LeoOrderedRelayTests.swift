import Testing

@testable import Ghostty

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
}

private actor Received {
    private(set) var values: [Int?] = []
    func append(_ value: Int?) { values.append(value) }
}
