import Foundation
import Testing

@testable import LeoKit

struct LeoChatTranscriptTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func message(
        _ id: String, _ kind: LeoChatMessage.Kind = .text, _ direction: LeoChatMessage.Direction = .outbound, at offset: TimeInterval,
        task: String? = nil
    ) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: "zeus", direction: direction, kind: kind, text: id, task: task, ts: base.addingTimeInterval(offset)
        )
    }

    /// The items as compact tags: `H` for a header, otherwise `id:position`.
    static func tags(_ messages: [LeoChatMessage]) -> [String] {
        LeoChatTranscript.items(for: messages).map { item in
            switch item {
            case .timeHeader: "H"
            case .message(let message, let position): "\(message.id):\(position)"
            }
        }
    }

    @Test func emptyInputGivesNoItems() {
        #expect(LeoChatTranscript.items(for: []).isEmpty)
    }

    @Test func aHeaderComesBeforeTheFirstMessage() {
        #expect(Self.tags([Self.message("a", at: 0)]) == ["H", "a:single"])
    }

    @Test func aHeaderFollowsAFifteenMinuteGap() {
        #expect(Self.tags([Self.message("a", at: 0), Self.message("b", at: 900)]) == ["H", "a:single", "H", "b:single"])
    }

    @Test func noHeaderJustUnderFifteenMinutes() {
        let tags = Self.tags([Self.message("a", at: 0), Self.message("b", at: 899)])
        #expect(tags == ["H", "a:single", "b:single"])
    }

    @Test func aDirectionChangeSplitsAGroup() {
        let tags = Self.tags([Self.message("a", at: 0), Self.message("b", .text, .inbound, at: 5)])
        #expect(tags == ["H", "a:single", "b:single"])
    }

    @Test func fiftyNineSecondsGroupsAndSixtySplits() {
        #expect(Self.tags([Self.message("a", at: 0), Self.message("b", at: 59)]) == ["H", "a:first", "b:last"])
        #expect(Self.tags([Self.message("a", at: 0), Self.message("b", at: 60)]) == ["H", "a:single", "b:single"])
    }

    @Test func aSystemOrTaskMessageBetweenTextsBreaksTheGroup() {
        for kind in [LeoChatMessage.Kind.system, .task] {
            let tags = Self.tags([Self.message("a", at: 0), Self.message("m", kind, at: 5), Self.message("b", at: 10)])
            #expect(tags == ["H", "a:single", "m:single", "b:single"])
        }
    }

    @Test func quickSameSenderTextsFormOneGroup() {
        let messages = (0..<4).map { Self.message("m\($0)", at: TimeInterval($0 * 10)) }
        #expect(Self.tags(messages) == ["H", "m0:first", "m1:middle", "m2:middle", "m3:last"])
    }

    @Test func aContinuingAskJoinsItsPostPastTheGroupGap() {
        let tags = Self.tags([Self.message("a", at: 0), Self.message("q", .ask, at: 120)])
        #expect(tags == ["H", "a:first", "q:last"])
    }

    @Test func aHeaderBetweenAPostAndItsAskSplitsThem() {
        let tags = Self.tags([Self.message("a", at: 0), Self.message("q", .ask, at: 1_000)])
        #expect(tags == ["H", "a:single", "H", "q:single"])
    }

    @Test func anAskContinuingATaskCardStaysSingle() {
        let tags = Self.tags([Self.message("t", .task, at: 0, task: "nightly"), Self.message("q", .ask, at: 5, task: "nightly")])
        #expect(tags == ["H", "t:single", "q:single"])
    }

    @Test func anUnknownKindIsNeverGrouped() {
        let tags = Self.tags([Self.message("a", at: 0), Self.message("u", .unknown, at: 5), Self.message("b", at: 10)])
        #expect(tags == ["H", "a:single", "u:single", "b:single"])
    }

    @Test func itemIDsAreUniqueAndStable() {
        let items = LeoChatTranscript.items(for: [Self.message("a", at: 0), Self.message("b", at: 2_000)])
        #expect(items.map(\.id) == ["time-a", "a", "time-b", "b"])
    }
}

struct LeoChatHeaderTextTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Thursday, 2026-10-15 1:30 PM.
    static let now = date(2026, 10, 15, 13, 30)

    static func header(_ date: Date, now: Date = now) -> LeoChatTranscript.HeaderText {
        LeoChatTranscript.headerText(date, calendar: calendar, now: now)
    }

    @Test(arguments: [
        (date(2026, 10, 15, 13, 6), "Today", "Today 1:06\u{202F}PM"),
        (date(2026, 10, 14, 9, 12), "Yesterday", "Yesterday 9:12\u{202F}AM"),
        (date(2026, 10, 13, 15, 0), "Tuesday", "Tuesday 3:00\u{202F}PM"),
        (date(2026, 10, 9, 15, 0), "Friday", "Friday 3:00\u{202F}PM"),
        (date(2026, 10, 8, 14, 0), "Thu, Oct 8", "Thu, Oct 8 at 2:00\u{202F}PM"),
        (date(2026, 10, 1, 14, 0), "Thu, Oct 1", "Thu, Oct 1 at 2:00\u{202F}PM"),
        (date(2025, 10, 3, 14, 0), "Oct 3, 2025", "Oct 3, 2025 at 2:00\u{202F}PM"),
    ])
    func eachDateBucketReadsLikeIMessage(date: Date, day: String, text: String) {
        let header = Self.header(date)
        #expect(header.day == day)
        #expect(header.text == text)
    }

    @Test func theBucketFollowsTheCalendarDayNotTwentyFourHours() {
        let header = Self.header(Self.date(2026, 10, 14, 23, 55), now: Self.date(2026, 10, 15, 0, 10))
        #expect(header.day == "Yesterday")
        #expect(header.time == "11:55\u{202F}PM")
    }
}
