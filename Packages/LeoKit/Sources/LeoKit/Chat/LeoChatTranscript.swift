import Foundation

/// How a chat thread lays out as an iMessage-style transcript: time headers
/// after pauses, and consecutive bubbles from one sender grouped so only the
/// last one carries a tail. Pure logic shared by the Mac and iOS views.
public enum LeoChatTranscript {
    /// A pause at least this long puts a time header above the next message.
    public static let timeHeaderGap: TimeInterval = 15 * 60
    /// Bubbles closer together than this (same sender) belong to one group.
    public static let groupGap: TimeInterval = 60

    /// Where a bubble sits in its group.
    public enum GroupPosition: Equatable, Sendable { case single, first, middle, last }

    public enum Item: Equatable, Identifiable, Sendable {
        /// `id` is `time-<id of the message it precedes>`.
        case timeHeader(Date, id: String)
        case message(LeoChatMessage, position: GroupPosition)

        public var id: String {
            switch self {
            case .timeHeader(_, let id): id
            case .message(let message, _): message.id
            }
        }
    }

    /// The transcript for `messages`, which must be sorted by `(ts, id)`.
    public static func items(for messages: [LeoChatMessage]) -> [Item] {
        let hasHeader = messages.indices.map { index in
            index == 0 || messages[index].ts.timeIntervalSince(messages[index - 1].ts) >= timeHeaderGap
        }
        let joinsPrevious = messages.indices.map { index in
            index > 0 && !hasHeader[index] && joins(messages[index], after: messages[index - 1])
        }
        return messages.indices.flatMap { index -> [Item] in
            let joinsNext = index + 1 < messages.count && joinsPrevious[index + 1]
            let message = messages[index]
            let item = Item.message(message, position: position(joinsPrevious: joinsPrevious[index], joinsNext: joinsNext))
            return hasHeader[index] ? [.timeHeader(message.ts, id: "time-\(message.id)"), item] : [item]
        }
    }

    private static func position(joinsPrevious: Bool, joinsNext: Bool) -> GroupPosition {
        switch (joinsPrevious, joinsNext) {
        case (false, false): .single
        case (false, true): .first
        case (true, true): .middle
        case (true, false): .last
        }
    }

    private static let bubbleKinds: Set<LeoChatMessage.Kind> = [.text, .voice, .file, .ask, .permission]

    private static func joins(_ message: LeoChatMessage, after previous: LeoChatMessage) -> Bool {
        bubbleKinds.contains(message.kind) && bubbleKinds.contains(previous.kind)
            && message.direction == previous.direction
            && message.senderLabel == previous.senderLabel
            && (message.ts.timeIntervalSince(previous.ts) < groupGap || message.continuesPost(after: previous))
    }

    /// A time header's wording: `day` is the part iMessage sets in semibold.
    public struct HeaderText: Equatable, Sendable {
        public let day: String
        public let time: String
        /// `day` and `time` joined as the header reads.
        public let text: String

        init(day: String, time: String, isDated: Bool = false) {
            self.day = day
            self.time = time
            text = isDated ? String(localized: "\(day) at \(time)") : "\(day) \(time)"
        }
    }

    private static let recentDays = 2...6

    /// "Today 1:06 PM", "Yesterday …", "Tuesday …" for the last week, then
    /// "Thu, Oct 3 at …", and with the year once it is not this one.
    /// The bucket is the calendar-day difference from `now`, not 24 h spans.
    public static func headerText(_ date: Date, calendar: Calendar, now: Date) -> HeaderText {
        let locale = calendar.locale ?? .autoupdatingCurrent
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        )
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch daysAgo {
        case 0: return HeaderText(day: String(localized: "Today"), time: time)
        case 1: return HeaderText(day: String(localized: "Yesterday"), time: time)
        case recentDays: return HeaderText(day: date.formatted(style.weekday(.wide)), time: time)
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let day = sameYear ? date.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
                : date.formatted(style.month(.abbreviated).day().year())
            return HeaderText(day: day, time: time, isDated: true)
        }
    }
}
