import Foundation

/// What a live dispatch row shows (B-257): a tinted role chip, its name,
/// and a trailing dot with the minutes it has run. Informational only: no
/// fill, no badge -- only the parent agent's pill asks for attention.
struct LeoDispatchRowPresentation: Equatable {
    /// Leading inset of a depth-0 child, inside its agent row.
    static let baseIndent: CGFloat = 12
    static let indentPerLevel: CGFloat = 12
    /// Deeper levels share the last indent, so the name keeps its room.
    static let maxIndentDepth = 4

    /// The role, drawn as a small tinted chip.
    struct RoleChip: Equatable {
        let text: String
        let tint: LeoTint
    }

    /// The trailing status: a dot, and the elapsed minutes (or a word).
    struct Status: Equatable {
        enum Dot: Equatable {
            case running, queued, idle, stalled

            var tint: LeoTint {
                switch self {
                case .running: .blue
                case .stalled: .orange
                case .queued, .idle: .gray
                }
            }

            /// Only a running dispatch pulses (and not under Reduce Motion).
            var pulses: Bool { self == .running }
            var isHollow: Bool { self == .queued }
        }

        let dot: Dot
        let text: String
        /// nil draws the text tertiary.
        let textTint: LeoTint?
    }

    let title: String
    /// False when the chip already says the role and there is no name.
    let showsTitle: Bool
    let roleChip: RoleChip?
    let status: Status
    let indent: CGFloat
    let accessibilityLabel: String

    /// `now` dates the elapsed time.
    init(_ node: LeoDispatchNode, now: Date = Date()) {
        let dispatch = node.dispatch
        title = dispatch.name ?? dispatch.role ?? "Dispatch"
        showsTitle = dispatch.name != nil || dispatch.role == nil
        roleChip = dispatch.role.map { RoleChip(text: $0, tint: Self.roleTint($0)) }
        let word = Self.statusWord(dispatch.status)
        status = Self.status(dispatch, word: word, now: now)
        indent = Self.baseIndent + CGFloat(min(node.depth, Self.maxIndentDepth)) * Self.indentPerLevel
        let kind = [node.depth == 0 ? nil : "nested", dispatch.role, "dispatch", dispatch.name].compactMap { $0 }.joined(separator: " ")
        accessibilityLabel = "\(kind), \(word)\(dispatch.stalled ? ", stalled" : "")"
    }

    /// explore = cyan, plan = purple, implement* = pink, review* = mint,
    /// anything else gray. The family is the part before the first ".".
    static func roleTint(_ role: String) -> LeoTint {
        switch role.split(separator: ".").first.map(String.init) {
        case "explore": .cyan
        case "plan": .purple
        case "implement": .pink
        case "review": .mint
        default: .gray
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

    private static func status(_ dispatch: LeoDispatch, word: String, now: Date) -> Status {
        let sinceStart = dispatch.startedAt.flatMap(LeoTimestamp.parse).map { Self.elapsed(now.timeIntervalSince($0)) }
        if dispatch.stalled {
            return Status(dot: .stalled, text: ["Stalled", sinceStart].compactMap { $0 }.joined(separator: " "), textTint: .orange)
        }
        let dot: Status.Dot = switch dispatch.status {
        case "running": .running
        case "queued": .queued
        default: .idle
        }
        return Status(dot: dot, text: sinceStart ?? word, textTint: nil)
    }

    /// "queued" → "Queued"; an unknown status still reads ("brand_new" →
    /// "Brand new").
    private static func statusWord(_ status: String) -> String {
        let words = status.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
