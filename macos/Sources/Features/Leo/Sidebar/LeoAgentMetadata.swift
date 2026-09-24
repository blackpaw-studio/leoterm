import Foundation

/// What a `/state` snapshot reported about one agent incarnation, beyond
/// its status (B-011, D-074). Every field is only what the daemon said:
/// missing stays missing.
struct LeoAgentMetadata: Equatable, Sendable {
    /// `last_activity_at`.
    let lastActiveAt: Date?
    /// The snapshot's `activity` was `working`: active as of the snapshot,
    /// so the row reads "now" however old `lastActiveAt` is.
    let isWorking: Bool
    /// `current_action.detail`, sanitized (agent-controlled text); never
    /// empty.
    let task: String?
}

/// One `/state` snapshot's metadata, keyed by name and applied as a whole.
/// An entry attaches to a row only when both carry the same `started_at`:
/// a snapshot requested before a delete + recreate describes the old
/// incarnation and must never paint its namesake (D-074).
struct LeoAgentMetadataIndex: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let startedAt: String
        let metadata: LeoAgentMetadata
    }

    private let entries: [String: Entry]

    static let empty = LeoAgentMetadataIndex(entries: [:])

    private init(entries: [String: Entry]) { self.entries = entries }

    init(state: [LeoObservedAgent]) {
        let pairs = state.compactMap { agent -> (String, Entry)? in
            guard let startedAt = agent.startedAt, !startedAt.isEmpty, let metadata = Self.metadata(agent) else { return nil }
            return (agent.name, Entry(startedAt: startedAt, metadata: metadata))
        }
        self.init(entries: Dictionary(pairs, uniquingKeysWith: { _, latest in latest }))
    }

    func metadata(name: String, startedAt: String?) -> LeoAgentMetadata? {
        guard let startedAt, let entry = entries[name], entry.startedAt == startedAt else { return nil }
        return entry.metadata
    }

    func attach(to rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.map { $0.withMetadata(metadata(name: $0.name, startedAt: $0.startedAt)) }
    }

    private static func metadata(_ agent: LeoObservedAgent) -> LeoAgentMetadata? {
        let lastActiveAt = agent.lastActivityAt.flatMap(LeoTimestamp.parse)
        let task = agent.currentAction?.detail.map(LeoSFTPServerText.sanitized).flatMap { $0.isEmpty ? nil : $0 }
        guard lastActiveAt != nil || task != nil else { return nil }
        return LeoAgentMetadata(lastActiveAt: lastActiveAt, isWorking: agent.activity == .working, task: task)
    }
}

/// RFC 3339 timestamps as the daemon writes them (Go `time.Time`), with or
/// without fractional seconds.
enum LeoTimestamp {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// The row's compact "last active" label: "now" under a minute, then
/// "5m", "3h", and past a day the date ("Sep 21"; with the year when it
/// isn't this one). A time in the future (clock skew) reads "now".
enum LeoRelativeTime {
    static func label(since date: Date, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch Span(since: date, now: now) {
        case .now: "now"
        case .minutes(let minutes): "\(minutes)m"
        case .hours(let hours): "\(hours)h"
        case .days: day(date, now: now, timeZone: timeZone, locale: locale)
        }
    }

    /// The same, as VoiceOver should say it.
    static func spokenLabel(since date: Date, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch Span(since: date, now: now) {
        case .now: "active now"
        case .minutes(let minutes): "last active \(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        case .hours(let hours): "last active \(hours) \(hours == 1 ? "hour" : "hours") ago"
        case .days: "last active \(day(date, now: now, timeZone: timeZone, locale: locale))"
        }
    }

    private enum Span {
        case now
        case minutes(Int)
        case hours(Int)
        case days

        static let minute: TimeInterval = 60
        static let hour: TimeInterval = 3600
        static let day: TimeInterval = 86400

        init(since date: Date, now: Date) {
            let elapsed = now.timeIntervalSince(date)
            switch elapsed {
            case ..<Self.minute: self = .now
            case ..<Self.hour: self = .minutes(Int(elapsed / Self.minute))
            case ..<Self.day: self = .hours(Int(elapsed / Self.hour))
            default: self = .days
            }
        }
    }

    private static func day(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }
}
