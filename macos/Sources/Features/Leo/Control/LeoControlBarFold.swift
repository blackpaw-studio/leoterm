import CoreGraphics

/// Which of the control bar's optional controls fit the content area's
/// width. The prompt field and the view switch always stay; when the rest
/// would squeeze the field below `promptMinWidth`, controls fold away in
/// this order: Compact, Clear, Interrupt (with its divider), Send. The verbs
/// stay in the toolbar's "⋯" menu and the Agents menu; Return still sends.
struct LeoControlBarFold: Equatable {
    let showsCompact: Bool
    let showsClear: Bool
    let showsInterrupt: Bool
    let showsSend: Bool

    static let promptMinWidth: CGFloat = 120

    private static let barPadding: CGFloat = 20
    private static let itemSpacing: CGFloat = 8
    private static let symbolButtonWidth: CGFloat = 28
    private static let sendButtonWidth: CGFloat = 24
    private static let dividerWidth: CGFloat = 1
    /// The Terminal | Chat switch with its unread badge.
    private static let viewSwitchWidth: CGFloat = 136

    /// Folded last to first: each entry is dropped when what is left still
    /// does not fit.
    private enum Control: CaseIterable { case send, interrupt, clear, compact }

    private static func requiredWidth(showing shown: Set<Control>) -> CGFloat {
        let divider = shown.contains(.interrupt)
        let buttons = shown.subtracting([.send]).count
        let itemCount = 2 + buttons + (shown.contains(.send) ? 1 : 0) + (divider ? 1 : 0)
        return barPadding + promptMinWidth + viewSwitchWidth + CGFloat(itemCount - 1) * itemSpacing
            + (shown.contains(.send) ? sendButtonWidth : 0) + CGFloat(buttons) * symbolButtonWidth + (divider ? dividerWidth : 0)
    }

    init(barWidth: CGFloat) {
        // Dropped from the least to the most important; a NaN width fits nothing.
        var shown = Set(Control.allCases)
        for dropped in [Control.compact, .clear, .interrupt, .send] where !(barWidth >= Self.requiredWidth(showing: shown)) {
            shown.remove(dropped)
        }
        showsCompact = shown.contains(.compact)
        showsClear = shown.contains(.clear)
        showsInterrupt = shown.contains(.interrupt)
        showsSend = shown.contains(.send)
    }
}
