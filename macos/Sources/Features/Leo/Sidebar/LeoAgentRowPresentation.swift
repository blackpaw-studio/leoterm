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

        var text: String { [template, state?.label].compactMap { $0 }.joined(separator: Self.separator) }

        static let separator = " · "
    }

    let badge: Badge?
    let subtitle: Subtitle?

    init(row: LeoAgentRow, isSelected: Bool) {
        let template = row.template.flatMap { $0.isEmpty ? nil : $0 }
        guard let attention = row.attention.map(LeoStatusPresentation.attention) else {
            badge = nil
            subtitle = template.map { Subtitle(template: $0, state: nil) }
            return
        }
        let tint = isSelected ? Color.primary : attention.color
        badge = Badge(symbolName: attention.symbolName, tint: tint)
        subtitle = Subtitle(template: template, state: State(label: attention.accessibilityLabel, tint: tint))
    }
}
