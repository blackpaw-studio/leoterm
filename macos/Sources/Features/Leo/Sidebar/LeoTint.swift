import AppKit
import SwiftUI

/// The semantic system hues the sidebar's symbols and state words are drawn
/// in. A value (not a `Color`) so presentation types stay `Equatable` and
/// tests can name a tint without comparing colors.
enum LeoTint: Equatable, Sendable {
    case orange, red, green, indigo, blue

    var nsColor: NSColor {
        switch self {
        case .orange: .systemOrange
        case .red: .systemRed
        case .green: .systemGreen
        case .indigo: .systemIndigo
        case .blue: .systemBlue
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// What a symbol or line of text is drawn in: a system hue, or one of the
/// calm greys. Colour is used only where the state changes what you'd do.
enum LeoInk: Equatable, Sendable {
    case tint(LeoTint)
    case secondary
    case tertiary

    /// A selected row keeps contrast by going white; a grey keeps its
    /// semantic level, which the selection already adapts.
    func style(isSelected: Bool) -> AnyShapeStyle {
        switch self {
        case .tint(let tint): AnyShapeStyle(isSelected ? Color.white : tint.color)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        }
    }
}
