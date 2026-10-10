import Foundation

/// What an agent row's state draws: the leading symbol and its ink, whether
/// the row has a second line, and what trails the name in place of the time.
/// Resolved from the row's attention, status, compaction and activity; first
/// match wins (see `State` for the order).
struct LeoAgentRowState: Equatable {
    /// In resolution order.
    enum State: Equatable {
        case needsYou, error, done, starting, stopped, unknown, compacting, working, idle
    }

    let state: State
    let symbolName: String
    let symbolInk: LeoInk
    /// Where the detail text sits: orange for needs-you, red for an error.
    let detailInk: LeoInk
    /// Whether the row has a detail line under its name. Fixed per state,
    /// so a tool starting never makes a row jump.
    let hasSecondLine: Bool
    /// A word in place of the time (e.g. "Compacting"); nil shows the time.
    let trailingWord: String?
    let trailingInk: LeoInk?
    /// Only a working agent's symbol turns (and not under Reduce Motion).
    let rotates: Bool
    /// A stopped agent's name reads secondary.
    let isNameDimmed: Bool
    /// Hover text; nil when the symbol says it all.
    let help: String?
    /// VoiceOver text: the state, with the reason ("Needs Permission, Bash")
    /// when there is one.
    let accessibilityLabel: String

    /// `error` is the row's last failed-action message, if any.
    /// `inWorkingSection` is the row sitting in the attention grouping's
    /// Working section: one line, the word trailing in place of the time.
    init(row: LeoAgentRow, error: String?, inWorkingSection: Bool = false) {
        let reason = row.attention == .needsInput ? row.attentionReason.map(LeoStatusPresentation.attentionReason) : nil
        let hasError = error.map { !$0.isEmpty } ?? false
        switch (row.attention, row.status, row.compaction, row.activity) {
        case (.needsInput, _, _, _):
            self.init(
                .needsYou, reason.map { $0.symbolName + ".fill" } ?? Self.needsYouSymbol, .tint(.orange),
                detailInk: .tint(.orange), hasSecondLine: true, help: reason?.tooltip,
                spoken: reason?.accessibilityLabel ?? "Needs you"
            )
        case (.errored, _, _, _), (_, _, _, _) where hasError:
            self.init(.error, "exclamationmark.triangle.fill", .tint(.red), detailInk: .tint(.red), hasSecondLine: true, spoken: "Error")
        case (.finished, _, _, _):
            self.init(.done, "checkmark.circle", .tint(.green), hasSecondLine: true, spoken: "Done")
        case (_, .starting, _, _):
            self.init(.starting, "ellipsis", .secondary, spoken: "Starting")
        case (_, .stopped, _, _):
            self.init(.stopped, "stop.fill", .tertiary, isNameDimmed: true, spoken: "Stopped")
        case (_, .unknown, _, _):
            self.init(.unknown, "questionmark", .tertiary, spoken: "Unknown")
        case (_, _, .some(let compaction), _):
            self.init(
                .compacting, Self.compactionSymbol, .tint(.indigo), trailing: ("Compacting", .tint(.indigo)),
                help: Self.compactingHelp(compaction), spoken: "Compacting"
            )
        case (.working, _, _, _), (_, _, _, .working):
            self.init(
                .working, "arrow.triangle.2.circlepath", .tint(.blue), hasSecondLine: !inWorkingSection,
                trailing: inWorkingSection ? ("Working", .tint(.blue)) : nil, rotates: true, spoken: "Working"
            )
        default:
            self.init(.idle, "moon", .tertiary, spoken: "Idle")
        }
    }

    private init(
        _ state: State, _ symbolName: String, _ symbolInk: LeoInk, detailInk: LeoInk = .secondary,
        hasSecondLine: Bool = false, trailing: (word: String, ink: LeoInk)? = nil, rotates: Bool = false,
        isNameDimmed: Bool = false, help: String? = nil, spoken: String
    ) {
        self.state = state
        self.symbolName = symbolName
        self.symbolInk = symbolInk
        self.detailInk = detailInk
        self.hasSecondLine = hasSecondLine
        trailingWord = trailing?.word
        trailingInk = trailing?.ink
        self.rotates = rotates
        self.isNameDimmed = isNameDimmed
        self.help = help
        accessibilityLabel = spoken
    }

    /// The state with a second line in orange, for an environment config
    /// problem (B-283) that must not hide on a one-line row. A state that
    /// already tints its detail (needs you, error) keeps its own ink.
    func showingWarning() -> Self {
        Self(copying: self, detailInk: detailInk == .secondary ? .tint(.orange) : detailInk, hasSecondLine: true)
    }

    private init(copying other: Self, detailInk: LeoInk, hasSecondLine: Bool) {
        state = other.state
        symbolName = other.symbolName
        symbolInk = other.symbolInk
        self.detailInk = detailInk
        self.hasSecondLine = hasSecondLine
        trailingWord = other.trailingWord
        trailingInk = other.trailingInk
        rotates = other.rotates
        isNameDimmed = other.isNameDimmed
        help = other.help
        accessibilityLabel = other.accessibilityLabel
    }

    static let needsYouSymbol = "questionmark.circle.fill"
    static let compactionSymbol = "arrow.down.right.and.arrow.up.left"
    private static let compactingLine = "Compacting context"

    private static func compactingHelp(_ compaction: LeoRowCompaction) -> String {
        switch compaction.trigger {
        case .auto: "\(compactingLine) (automatic)"
        case .manual: "\(compactingLine) (requested)"
        case nil: compactingLine
        }
    }
}
