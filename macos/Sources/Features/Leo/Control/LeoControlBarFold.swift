import CoreGraphics

/// Which of the control bar's optional verbs fit the content area's width.
/// The prompt field keeps `promptMinWidth`; when the rest would squeeze it
/// below that, Compact folds away first, then Clear. Both stay in the
/// toolbar's "⋯" menu and the Agents menu.
struct LeoControlBarFold: Equatable {
    let showsCompact: Bool
    let showsClear: Bool

    static let promptMinWidth: CGFloat = 120

    private static let barPadding: CGFloat = 20
    private static let itemSpacing: CGFloat = 8
    private static let symbolButtonWidth: CGFloat = 28
    private static let sendButtonWidth: CGFloat = 24
    private static let dividerWidth: CGFloat = 1
    /// The Terminal | Chat switch with its unread badge.
    private static let viewSwitchWidth: CGFloat = 160

    /// The width needed with the prompt at its minimum, the send button,
    /// Interrupt, the divider and the switch, plus `optionalVerbs` more buttons.
    private static func requiredWidth(optionalVerbs: Int) -> CGFloat {
        let fixedItems = 5 + optionalVerbs
        let spacing = CGFloat(fixedItems - 1) * itemSpacing
        return barPadding + promptMinWidth + sendButtonWidth + symbolButtonWidth * CGFloat(1 + optionalVerbs)
            + dividerWidth + viewSwitchWidth + spacing
    }

    init(barWidth: CGFloat) {
        // A NaN width compares false: everything folds.
        showsClear = barWidth >= Self.requiredWidth(optionalVerbs: 1)
        showsCompact = barWidth >= Self.requiredWidth(optionalVerbs: 2)
    }
}
