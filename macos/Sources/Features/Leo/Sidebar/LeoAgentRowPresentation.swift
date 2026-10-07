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
        /// Hover text naming why the agent needs input; nil without a reason.
        var tooltip: String?
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
        /// B-259: "12.3k tok · $0.42 · 37% ctx", the session's usage; nil
        /// when the daemon didn't advertise it or reported nothing.
        var usage: String?
        /// The whole usage numbers for the hover.
        var usageTooltip: String?
        /// `usage` as VoiceOver says it.
        var usageSpoken: String?

        var text: String { [template, state?.label, usage, lastActive].compactMap { $0 }.joined(separator: Self.separator) }

        /// The hover: the line, then the usage numbers behind it.
        var help: String { [text, usageTooltip].compactMap { $0 }.joined(separator: "\n") }

        /// The template, usage and the time; the state is already on the name's label.
        var accessibilityLabel: String { [template, usageSpoken, lastActiveSpoken].compactMap { $0 }.joined(separator: ", ") }

        static let separator = " · "

        /// Which part of the line gives way first when it's too narrow.
        enum Truncation: Equatable {
            /// The usage: gives way before anything else.
            case usage
            /// The template: truncates once the usage is gone.
            case first
            /// The attention state: truncates once the template is gone.
            case second
            /// The last-active time: never truncates.
            case never

            var layoutPriority: Double {
                switch self {
                case .usage: -1
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

        /// Template, state, usage, time -- in that order, missing parts omitted.
        var segments: [Segment] {
            let parts: [(String, Tint, Truncation)?] = [
                template.map { ($0, .secondary, .first) },
                state.map { ($0.label, .state($0.tint), .second) },
                usage.map { ($0, .secondary, .usage) },
                lastActive.map { ($0, .secondary, .never) }
            ]
            return parts.compactMap { $0 }.enumerated().map { index, part in
                Segment(text: part.0, tint: part.1, truncation: part.2, hasSeparator: index > 0)
            }
        }
    }

    let badge: Badge?
    let subtitle: Subtitle?
    /// The agent's current task (already sanitized), for its own line.
    let task: String?
    /// B-259: the last turn's preview as one line, only while the row has
    /// no task line (the task is what the agent is doing now, the preview
    /// what it just did). An aborted turn is labelled so.
    let turnPreview: String?

    /// `now` dates the "last active" label; without it (no clock yet) the
    /// subtitle has no time. Metadata the daemon didn't report adds nothing.
    init(
        row: LeoAgentRow, isSelected: Bool, now: Date? = nil,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        let template = row.template.flatMap { $0.isEmpty ? nil : $0 }
        task = row.metadata?.task
        turnPreview = task == nil ? row.lastTurn.map(Self.turnLine) : nil
        let attention = row.attention.map(LeoStatusPresentation.attention)
        // On a selected row the state drops to the primary color for contrast.
        let tint = { (presentation: LeoStatusPresentation.Presentation) in isSelected ? Color.primary : presentation.color }
        let reason = row.attention == .needsInput ? row.attentionReason.map(LeoStatusPresentation.attentionReason) : nil
        badge = attention.map { Badge(symbolName: reason?.symbolName ?? $0.symbolName, tint: tint($0), tooltip: reason?.tooltip) }
        let state = attention.map { State(label: reason?.stateWord ?? $0.accessibilityLabel, tint: tint($0)) }
        let active = Self.lastActive(row.metadata, now: now)
        let lastActive = active.map { LeoRelativeTime.label(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        let spoken = active.map { LeoRelativeTime.spokenLabel(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        let usage = row.metadata?.usage.flatMap { LeoUsageFormat.isEmpty($0) ? nil : $0 }
        subtitle = template == nil && state == nil && lastActive == nil && usage == nil
            ? nil
            : Subtitle(
                template: template, state: state, lastActive: lastActive, lastActiveSpoken: spoken,
                usage: usage.map(LeoUsageFormat.summary), usageTooltip: usage.map(LeoUsageFormat.tooltip),
                usageSpoken: usage.map(LeoUsageFormat.spoken)
            )
    }

    private static func turnLine(_ turn: LeoTurnPreview) -> String {
        let text = LeoSFTPServerText.isolated(turn.text)
        return turn.outcome == .aborted ? "Interrupted: \(text)" : text
    }

    /// A working agent is active now, whatever its last reported time.
    private static func lastActive(_ metadata: LeoAgentMetadata?, now: Date?) -> (date: Date, now: Date)? {
        guard let metadata, let now else { return nil }
        if metadata.isWorking { return (now, now) }
        return metadata.lastActiveAt.map { ($0, now) }
    }
}
