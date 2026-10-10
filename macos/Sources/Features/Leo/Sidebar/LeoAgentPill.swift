import Foundation

/// The coloured state pill on an agent row's second line: one word, one
/// symbol, one tint, resolved from the row's attention, status, compaction
/// and activity. First match wins (see `State` for the order).
struct LeoAgentPill: Equatable {
    /// In resolution order.
    enum State: Equatable {
        case needsYou, error, done, starting, stopped, unknown, compacting, working, idle
    }

    let state: State
    let word: String
    let symbolName: String
    let tint: LeoTint
    /// Stopped alone is drawn as an outline instead of a fill.
    let isOutlined: Bool
    /// Hover text; nil when the word says it all.
    let help: String?
    /// VoiceOver text: the reason ("Needs Permission, Bash") when there is one.
    let accessibilityLabel: String

    /// `error` is the row's last failed-action message, if any.
    init(row: LeoAgentRow, error: String?) {
        let reason = row.attention == .needsInput ? row.attentionReason.map(LeoStatusPresentation.attentionReason) : nil
        let hasError = error.map { !$0.isEmpty } ?? false
        switch (row.attention, row.status, row.compaction, row.activity) {
        case (.needsInput, _, _, _):
            self.init(.needsYou, "Needs you", reason?.symbolName ?? Self.needsYouSymbol, .orange, help: reason?.tooltip,
                      spoken: reason?.accessibilityLabel)
        case (.errored, _, _, _), (_, _, _, _) where hasError:
            self.init(.error, "Error", "exclamationmark.triangle.fill", .red)
        case (.finished, _, _, _):
            self.init(.done, "Done", "checkmark", .green)
        case (_, .starting, _, _):
            self.init(.starting, "Starting", "ellipsis", .gray)
        case (_, .stopped, _, _):
            self.init(.stopped, "Stopped", "stop.fill", .gray, isOutlined: true)
        case (_, .unknown, _, _):
            self.init(.unknown, "Unknown", "questionmark", .gray)
        case (_, _, .some(let compaction), _):
            self.init(.compacting, "Compacting", Self.compactionSymbol, .indigo, help: Self.compactingHelp(compaction))
        case (.working, _, _, _), (_, _, _, .working):
            self.init(.working, "Working", "gearshape", .blue)
        default:
            self.init(.idle, "Idle", "moon.fill", .gray)
        }
    }

    private init(
        _ state: State, _ word: String, _ symbolName: String, _ tint: LeoTint,
        isOutlined: Bool = false, help: String? = nil, spoken: String? = nil
    ) {
        self.state = state
        self.word = word
        self.symbolName = symbolName
        self.tint = tint
        self.isOutlined = isOutlined
        self.help = help
        accessibilityLabel = spoken ?? word
    }

    static let needsYouSymbol = "questionmark.circle"
    static let compactionSymbol = "arrow.down.right.and.arrow.up.left"
    /// A pill on a selected row: the fill is white at this opacity.
    static let selectedFillOpacity = 0.22

    static func fillOpacity(isDark: Bool) -> Double { LeoTint.fillOpacity(isDark: isDark) }

    private static let compactingLine = "Compacting context"

    private static func compactingHelp(_ compaction: LeoRowCompaction) -> String {
        switch compaction.trigger {
        case .auto: "\(compactingLine) (automatic)"
        case .manual: "\(compactingLine) (requested)"
        case nil: compactingLine
        }
    }
}
