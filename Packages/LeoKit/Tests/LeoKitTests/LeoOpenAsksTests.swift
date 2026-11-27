import Foundation
import Testing

@testable import LeoKit

struct LeoOpenAsksTests {
    typealias Fx = LeoInboxFixtures

    private func names(_ asks: LeoOpenAsks, host: LeoHostID = Fx.host) -> [String] {
        asks.threads(host: host).values.flatMap(\.asks).map(\.id).sorted()
    }

    @Test func aHostIsSeededBySeedAloneAndUnseededOnDisconnect() {
        var asks = LeoOpenAsks()
        #expect(!asks.isSeeded(host: Fx.host))

        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus")))
        #expect(!asks.isSeeded(host: Fx.host))

        asks.seed(host: Fx.host, messages: [], complete: true)
        #expect(asks.isSeeded(host: Fx.host))
        #expect(!asks.isSeeded(host: .local))

        asks.disconnect(host: Fx.host)
        #expect(!asks.isSeeded(host: Fx.host))
    }

    @Test func aCompleteSeedReplacesTheHostsAsks() {
        var asks = LeoOpenAsks()
        asks.seed(host: Fx.host, messages: [Fx.ask("old", agent: "zeus")], complete: true)
        asks.seed(host: Fx.host, messages: [Fx.ask("new", agent: "hera"), Fx.ask("done", agent: "ares", state: "answered")], complete: true)

        #expect(names(asks) == ["new"])
    }

    @Test func aPartialSeedAddsOpenAsksAndKeepsLiveOnes() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("live", agent: "zeus")))
        asks.seed(host: Fx.host, messages: [Fx.ask("last", agent: "hera")], complete: false)

        #expect(names(asks) == ["last", "live"])
    }

    @Test func aPartialSeedWithASettledMessageRemovesThatAsk() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus")))
        asks.seed(host: Fx.host, messages: [Fx.ask("m1", agent: "zeus", state: "answered")], complete: false)

        #expect(names(asks).isEmpty)
    }

    @Test func aLiveOpenAskAppearsAndSettlingRemovesIt() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus", at: 5)))
        #expect(asks.threads(host: Fx.host)[Fx.id("zeus")]?.asks.map(\.id) == ["m1"])

        asks.apply(host: Fx.host, event: .updated(Fx.ask("m1", agent: "zeus", state: "answered", at: 5)))
        #expect(names(asks).isEmpty)
    }

    @Test func aSettledAskStaysGoneWhenAStaleSeedArrivesLater() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .updated(Fx.ask("m1", agent: "zeus", state: "expired")))
        asks.seed(host: Fx.host, messages: [Fx.ask("m1", agent: "zeus")], complete: false)

        #expect(names(asks).isEmpty)
    }

    @Test func permissionRowsCountAsOpenAsksButPlainMessagesDoNot() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("p1", agent: "zeus", kind: .permission)))
        asks.apply(host: Fx.host, event: .message(Fx.chat("t1", agent: "hera", text: "hello")))

        #expect(names(asks) == ["p1"])
    }

    @Test func theAsksContextIsTheAgentsLastMessageBeforeIt() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.chat("t1", agent: "zeus", text: "first", at: 1)))
        asks.apply(host: Fx.host, event: .message(Fx.chat("t2", agent: "zeus", text: "I checked the build", at: 2)))
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus", at: 3)))
        asks.apply(host: Fx.host, event: .message(Fx.chat("t3", agent: "zeus", text: "later chatter", at: 4)))

        #expect(asks.threads(host: Fx.host)[Fx.id("zeus")]?.context == "I checked the build")
    }

    @Test func anUpdateToAnOpenAskKeepsItsContextAndPosition() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.chat("t1", agent: "zeus", text: "context", at: 1)))
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus", at: 2)))
        asks.apply(host: Fx.host, event: .updated(Fx.ask("m1", agent: "zeus", at: 2)))

        let thread = asks.threads(host: Fx.host)[Fx.id("zeus")]
        #expect(thread?.asks.count == 1)
        #expect(thread?.context == "context")
    }

    @Test func aSeededThreadsLastMessageProvidesContextForLaterAsks() {
        var asks = LeoOpenAsks()
        asks.seed(host: Fx.host, messages: [Fx.chat("t1", agent: "zeus", text: "progress", at: 1)], complete: false)
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus", at: 2)))

        #expect(asks.threads(host: Fx.host)[Fx.id("zeus")]?.context == "progress")
    }

    @Test func asksAreOrderedOldestFirstPerAgent() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("late", agent: "zeus", at: 9)))
        asks.apply(host: Fx.host, event: .message(Fx.ask("early", agent: "zeus", at: 1)))

        #expect(asks.threads(host: Fx.host)[Fx.id("zeus")]?.asks.map(\.id) == ["early", "late"])
    }

    @Test func disconnectDropsOnlyThatHostsAsks() {
        var asks = LeoOpenAsks()
        asks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus")))
        asks.apply(host: .local, event: .message(Fx.ask("m2", agent: "hera")))

        asks.disconnect(host: Fx.host)

        #expect(names(asks).isEmpty)
        #expect(names(asks, host: .local) == ["m2"])
        #expect(asks.threads.keys.map(\.host) == [.local])
    }
}
