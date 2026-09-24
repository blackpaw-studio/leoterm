import SwiftUI

/// What an agent row draws for its attention state and subtitle.
///
/// The trailing attention badge is icon-only (symbol plus state tint) so it
/// never costs the name width; the state word moves to the subtitle line
/// ("claude · Needs Input") in the state color. On a selected row both drop
/// to the primary color so they keep contrast against the selection.
struct LeoAgentRowPresentation: Equatable {
    struct Badge: Equatable {
        let symbolName: String
        let tint: Color
    }

    struct State: Equatable {
        let label: String
        let tint: Color
    }

    struct Subtitle: Equatable {
        let template: String?
        let state: State?
        /// "5m": when the agent was last active, in secondary text.
        var lastActive: String?
        /// `lastActive` as VoiceOver says it ("last active 5 minutes ago").
        var lastActiveSpoken: String?

        var text: String { [template, state?.label, lastActive].compactMap { $0 }.joined(separator: Self.separator) }

        /// The template and the time; the state is already on the name's label.
        var accessibilityLabel: String { [template, lastActiveSpoken].compactMap { $0 }.joined(separator: ", ") }

        static let separator = " · "

        /// Which part of the line gives way first when it's too narrow.
        enum Truncation: Equatable {
            /// The template: truncates first.
            case first
            /// The attention state: truncates once the template is gone.
            case second
            /// The last-active time: never truncates.
            case never

            var layoutPriority: Double {
                switch self {
                case .first: 0
                case .second: 1
                case .never: 2
                }
            }
        }

        enum Tint: Equatable {
            case secondary
            case state(Color)
        }

        /// One part of the line, drawn as its own text so each truncates
        /// on its own terms; the separator leads the part it belongs to.
        struct Segment: Equatable {
            let text: String
            let tint: Tint
            let truncation: Truncation
            let hasSeparator: Bool
        }

        /// Template, state, time -- in that order, missing parts omitted.
        var segments: [Segment] {
            let parts: [(String, Tint, Truncation)?] = [
                template.map { ($0, .secondary, .first) },
                state.map { ($0.label, .state($0.tint), .second) },
                lastActive.map { ($0, .secondary, .never) }
            ]
            return parts.compactMap { $0 }.enumerated().map { index, part in
                Segment(text: part.0, tint: part.1, truncation: part.2, hasSeparator: index > 0)
            }
        }
    }

    /// Live attach tabs/splits for the agent: a secondary glyph, with the
    /// number only from two up (one tab is the common case, not news).
    struct Tabs: Equatable {
        let countText: String?
        let accessibilityLabel: String

        static let symbolName = "macwindow"

        init?(count: Int) {
            guard count > 0 else { return nil }
            countText = count >= 2 ? "\(count)" : nil
            accessibilityLabel = count == 1 ? "1 open tab" : "\(count) open tabs"
        }
    }

    let badge: Badge?
    let subtitle: Subtitle?
    let tabs: Tabs?
    /// The agent's current task (already sanitized), for its own line.
    let task: String?

    /// `now` dates the "last active" label; without it (no clock yet) the
    /// subtitle has no time. Metadata the daemon didn't report adds nothing.
    init(
        row: LeoAgentRow, isSelected: Bool, tabCount: Int = 0, now: Date? = nil,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        let template = row.template.flatMap { $0.isEmpty ? nil : $0 }
        tabs = Tabs(count: tabCount)
        task = row.metadata?.task
        let attention = row.attention.map(LeoStatusPresentation.attention)
        // On a selected row the state drops to the primary color for contrast.
        let tint = { (presentation: LeoStatusPresentation.Presentation) in isSelected ? Color.primary : presentation.color }
        badge = attention.map { Badge(symbolName: $0.symbolName, tint: tint($0)) }
        let state = attention.map { State(label: $0.accessibilityLabel, tint: tint($0)) }
        let active = Self.lastActive(row.metadata, now: now)
        let lastActive = active.map { LeoRelativeTime.label(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        let spoken = active.map { LeoRelativeTime.spokenLabel(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        subtitle = template == nil && state == nil && lastActive == nil
            ? nil
            : Subtitle(template: template, state: state, lastActive: lastActive, lastActiveSpoken: spoken)
    }

    /// A working agent is active now, whatever its last reported time.
    private static func lastActive(_ metadata: LeoAgentMetadata?, now: Date?) -> (date: Date, now: Date)? {
        guard let metadata, let now else { return nil }
        if metadata.isWorking { return (now, now) }
        return metadata.lastActiveAt.map { ($0, now) }
    }
}
