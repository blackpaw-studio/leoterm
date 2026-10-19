import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct SettleRevealTests {
    static let open = LeoChatMessage.make("01", kind: .ask, state: "open")
    static let settled = LeoChatMessage.make("01", kind: .ask, state: "expired", closedReason: "timeout")

    static func thread(_ message: LeoChatMessage?) -> IdentifiedArrayOf<LeoChatMessage> {
        message.map { [$0] } ?? []
    }

    @Test func aSettlementTheUserDidNotTriggerIsNotRevealed() {
        var reveal = SettleReveal()
        #expect(reveal.settled(in: Self.thread(Self.open), answering: []) == nil)
        #expect(reveal.settled(in: Self.thread(Self.settled), answering: []) == nil)
    }

    @Test func aCardTheUserActedOnIsRevealedOnceItSettles() {
        var reveal = SettleReveal()
        reveal.acted(on: "01")
        #expect(reveal.settled(in: Self.thread(Self.open), answering: ["01"]) == nil)
        #expect(reveal.settled(in: Self.thread(Self.settled), answering: []) == "01")
        // The claim is spent: a later settle of the same id is not the user's doing.
        #expect(reveal.settled(in: Self.thread(Self.settled), answering: []) == nil)
    }

    @Test func aRequestThatEndsWithoutSettlingDropsTheClaim() {
        var reveal = SettleReveal()
        reveal.acted(on: "01")
        #expect(reveal.settled(in: Self.thread(Self.open), answering: ["01"]) == nil)
        #expect(reveal.settled(in: Self.thread(Self.open), answering: []) == nil)
        // The card times out later, on its own.
        #expect(reveal.settled(in: Self.thread(Self.settled), answering: []) == nil)
    }

    @Test func aCardThatLeavesTheThreadDropsTheClaim() {
        var reveal = SettleReveal()
        reveal.acted(on: "01")
        #expect(reveal.settled(in: Self.thread(nil), answering: []) == nil)
        #expect(reveal.settled(in: Self.thread(Self.settled), answering: []) == nil)
    }
}
