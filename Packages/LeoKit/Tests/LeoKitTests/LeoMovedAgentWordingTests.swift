import Foundation
import Testing

@testable import LeoKit

/// B-324: deleting a moved agent's dormant record on its old host removes only
/// that host's leftover copy; the wording says so on both platforms.
struct LeoMovedAgentWordingTests {
    @Test func theLeftoverCopyPromptNamesBothHosts() {
        #expect(
            LeoMovedAgentWording.removeLeftoverTitle(on: "this Mac", movedTo: "nas")
                == "Remove leftover copy on this Mac (the agent lives on nas)"
        )
    }

    @Test func theLeftoverCopyButtonSaysRemove() {
        #expect(LeoMovedAgentWording.removeLeftoverButton == "Remove")
    }
}

struct LeoMovedAtTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    private static let us = Locale(identifier: "en_US")

    @Test func aTimestampWithNanosecondsParses() throws {
        let date = try #require(LeoMovedAgentWording.date(from: "2026-10-28T17:00:00.123456789Z"))
        #expect(date == LeoMovedAgentWording.date(from: "2026-10-28T17:00:00.123Z"))
        #expect(LeoMovedAgentWording.date(from: "2026-10-28T17:00:00Z") != nil)
        #expect(LeoMovedAgentWording.date(from: "yesterday") == nil)
    }

    @Test func theRowTextNamesTheHostAndHowLongAgo() throws {
        let at = try #require(LeoMovedAgentWording.date(from: "2026-10-28T17:00:00Z"))
        let text = LeoMovedAgentWording.movedText(host: "nas", at: "2026-10-28T17:00:00Z", now: at.addingTimeInterval(300), locale: Self.us)
        #expect(text == "Moved to nas · 5 minutes ago")
    }

    @Test func withoutAReadableTimeItIsTheHostAlone() {
        #expect(LeoMovedAgentWording.movedText(host: "nas", at: nil, now: Self.now, locale: Self.us) == "Moved to nas")
        #expect(LeoMovedAgentWording.movedText(host: "nas", at: "soon", now: Self.now, locale: Self.us) == "Moved to nas")
    }
}
