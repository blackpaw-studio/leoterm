import Foundation

/// What an agent row's two lines say: the state pill, then one detail
/// string, with the last-active time trailing the name. Pure value; the
/// views only draw it.
struct LeoAgentRowPresentation: Equatable {
    /// The one string on line 2, in precedence order (first present wins).
    /// The last case always has text, so the line is never blank.
    enum Detail: Equatable {
        /// Why the agent needs input: "Bash: rm -rf build".
        case attention(String)
        /// The row's last failed-action message (drawn red).
        case error(String)
        /// A named-environment config problem (B-283), drawn plain orange.
        case warning(String)
        case task(String)
        /// The running tool's name only.
        case tool(String)
        /// The last turn's preview ("Interrupted: …" when aborted).
        case turnPreview(String)
        /// "claude · $0.42": the template and the session's cost.
        case fallback(String)

        var text: String {
            switch self {
            case .attention(let text), .error(let text), .warning(let text), .task(let text), .tool(let text), .turnPreview(let text), .fallback(let text):
                text
            }
        }
    }

    let pill: LeoAgentPill
    let detail: Detail
    /// "5m": when the agent was last active; nil without a clock or a time.
    let lastActive: String?
    /// `lastActive` as VoiceOver says it ("last active 5 minutes ago").
    let lastActiveSpoken: String?
    /// The row's hover: the template, then the usage numbers. May be empty.
    let help: String
    /// A stopped agent's name reads secondary.
    let isNameDimmed: Bool

    /// What the fallback says when there is neither a template nor any spend.
    static let emptyFallback = "No activity yet"

    /// `now` dates the "last active" label; without it (no clock yet) the
    /// row has no time. Metadata the daemon didn't report adds nothing.
    init(
        row: LeoAgentRow, error: String?, now: Date? = nil,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) {
        pill = LeoAgentPill(row: row, error: error)
        let template = row.template.flatMap { $0.isEmpty ? nil : $0 }
        let usage = row.metadata?.usage.flatMap { LeoUsageFormat.isEmpty($0) ? nil : $0 }
        detail = Self.detail(row: row, error: error, template: template, usage: usage)
        let active = Self.lastActive(row.metadata, now: now)
        lastActive = active.map { LeoRelativeTime.label(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        lastActiveSpoken = active.map { LeoRelativeTime.spokenLabel(since: $0.date, now: $0.now, timeZone: timeZone, locale: locale) }
        let environments = Self.overrideNames(row.environments)
        help = [template, environments.map { "Environments: \($0)" }, usage.map(LeoUsageFormat.tooltip)].compactMap { $0 }.joined(separator: "\n")
        isNameDimmed = row.status == .stopped
    }

    /// "alpha, Needs Permission, Bash": the name's label, which carries the
    /// state the (hidden) pill draws.
    func accessibilityLabel(name: String) -> String { "\(name), \(pill.accessibilityLabel)" }

    private static func detail(row: LeoAgentRow, error: String?, template: String?, usage: LeoAgentUsage?) -> Detail {
        let metadata = row.metadata
        let reason = row.attention == .needsInput ? row.attentionReason : nil
        let attention = reason.flatMap { [$0.tool, $0.detail].compactMap { $0 }.nonEmptyJoined(": ") }
        if let attention { return .attention(attention) }
        if let error, !error.isEmpty { return .error(error) }
        if let warning = row.environments?.error, !warning.isEmpty { return .warning(warning) }
        if let task = metadata?.task { return .task(task) }
        if let tool = metadata?.tool { return .tool(tool) }
        if let turn = row.lastTurn { return .turnPreview(turnLine(turn)) }
        let environments = overrideNames(row.environments).map { "env: \($0)" }
        let fallback = [template, environments, usage.map { LeoUsageFormat.cost($0.session.costUSD) }].compactMap { $0 }.nonEmptyJoined(" · ")
        return .fallback(fallback ?? emptyFallback)
    }

    /// "aws, prod": an override's names, in order; nil for the default.
    private static func overrideNames(_ environments: LeoAgentEnvironments?) -> String? {
        guard let environments, environments.isOverride else { return nil }
        return environments.names.nonEmptyJoined(", ")
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

private extension Array where Element == String {
    /// The parts joined, or nil when there are none.
    func nonEmptyJoined(_ separator: String) -> String? {
        isEmpty ? nil : joined(separator: separator)
    }
}
