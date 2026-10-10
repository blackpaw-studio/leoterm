import Foundation

/// What a live dispatch row shows (B-257): a role glyph whose colour is the
/// status, its name, and the minutes it has run. Informational only: no
/// fill, no badge -- only the parent agent's row asks for attention.
struct LeoDispatchRowPresentation: Equatable {
    /// The glyph sits on the parent agent's name column, plus this much per
    /// level of depth.
    static let indentPerLevel: CGFloat = 16
    /// Deeper levels share the last indent, so the name keeps its room.
    static let maxIndentDepth = 4

    /// Where a dispatch is in its life, as the glyph's colour tells it.
    enum Phase: Equatable {
        case running, queued, idle, stalled

        var ink: LeoInk {
            switch self {
            case .running: .tint(.blue)
            case .stalled: .tint(.orange)
            case .queued, .idle: .tertiary
            }
        }
    }

    /// The trailing elapsed time (or a word).
    struct Status: Equatable {
        let text: String
        /// nil draws the text tertiary.
        let textTint: LeoTint?
    }

    let title: String
    /// The row's tooltip: the name, then the full role when it adds to it.
    let help: String
    /// The role's SF Symbol.
    let roleGlyph: String
    let phase: Phase
    let status: Status
    let indent: CGFloat
    let accessibilityLabel: String

    var glyphInk: LeoInk { phase.ink }
    /// Secondary; a queued dispatch's title waits a step quieter.
    var titleInk: LeoInk { phase == .queued ? .tertiary : .secondary }

    /// `now` dates the elapsed time.
    init(_ node: LeoDispatchNode, now: Date = Date()) {
        let dispatch = node.dispatch
        title = dispatch.name ?? dispatch.role ?? "Dispatch"
        help = dispatch.name.flatMap { name in dispatch.role.map { "\(name) · \($0)" } } ?? title
        roleGlyph = Self.roleGlyph(dispatch.role)
        let word = Self.statusWord(dispatch.status)
        phase = Self.phase(dispatch)
        status = Self.status(dispatch, word: word, now: now)
        indent = LeoAgentRowMetrics.nameColumnInset + CGFloat(min(node.depth, Self.maxIndentDepth)) * Self.indentPerLevel
        let kind = [node.depth == 0 ? nil : "nested", dispatch.role, "dispatch", dispatch.name].compactMap { $0 }.joined(separator: " ")
        accessibilityLabel = "\(kind), \(word)\(dispatch.stalled ? ", stalled" : "")"
    }

    /// explore = magnifier, plan = list, implement* = code, review* = eye,
    /// anything else a dashed circle. The family is the part before the
    /// first ".".
    static func roleGlyph(_ role: String?) -> String {
        switch role?.split(separator: ".").first.map(String.init) {
        case "explore": "magnifyingglass"
        case "plan": "list.bullet"
        case "implement": "chevron.left.forwardslash.chevron.right"
        case "review": "eye"
        default: "circle.dashed"
        }
    }

    /// Whole minutes: "<1m", "4m", "1h 12m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / secondsPerMinute)
        switch minutes {
        case 0: return "<1m"
        case ..<minutesPerHour: return "\(minutes)m"
        default: return "\(minutes / minutesPerHour)h \(minutes % minutesPerHour)m"
        }
    }

    private static let secondsPerMinute: TimeInterval = 60
    private static let minutesPerHour = 60

    private static func phase(_ dispatch: LeoDispatch) -> Phase {
        if dispatch.stalled { return .stalled }
        switch dispatch.status {
        case "running": return .running
        case "queued": return .queued
        default: return .idle
        }
    }

    private static func status(_ dispatch: LeoDispatch, word: String, now: Date) -> Status {
        let sinceStart = dispatch.startedAt.flatMap(LeoTimestamp.parse).map { Self.elapsed(now.timeIntervalSince($0)) }
        if dispatch.stalled {
            return Status(text: ["Stalled", sinceStart].compactMap { $0 }.joined(separator: " "), textTint: .orange)
        }
        return Status(text: sinceStart ?? word, textTint: nil)
    }

    /// "queued" → "Queued"; an unknown status still reads ("brand_new" →
    /// "Brand new").
    private static func statusWord(_ status: String) -> String {
        let words = status.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
