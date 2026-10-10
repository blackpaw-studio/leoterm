import AppKit
import SwiftUI

/// The semantic system hues the sidebar's pills, chips and dots are drawn in.
/// A value (not a `Color`) so presentation types stay `Equatable` and tests
/// can name a tint without comparing colors.
enum LeoTint: Equatable, Sendable {
    case orange, red, green, gray, indigo, blue, cyan, purple, brown, mint

    var nsColor: NSColor {
        switch self {
        case .orange: .systemOrange
        case .red: .systemRed
        case .green: .systemGreen
        case .gray: .systemGray
        case .indigo: .systemIndigo
        case .blue: .systemBlue
        case .cyan: .systemCyan
        case .purple: .systemPurple
        case .brown: .systemBrown
        case .mint: .systemMint
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// How a tinted pill, chip or dot paints itself: the tint at a low-opacity
/// fill with the tint as content, or -- on a selected row, where a system
/// tint would lose contrast against the selection -- white on a white wash.
struct LeoTintedStyle: Equatable {
    enum Paint: Equatable {
        case tint(LeoTint)
        case white

        var color: Color {
            switch self {
            case .tint(let tint): tint.color
            case .white: .white
            }
        }
    }

    /// A tinted fill's opacity, a little stronger on a dark background where
    /// the same alpha reads fainter; and a selected row's white wash.
    static let lightFillOpacity = 0.15
    static let darkFillOpacity = 0.20
    static let selectedFillOpacity = 0.22

    /// Text, symbol, dot or outline.
    let content: Paint
    let fill: Paint
    let fillOpacity: Double

    init(tint: LeoTint, isSelected: Bool, isDark: Bool) {
        let paint: Paint = isSelected ? .white : .tint(tint)
        content = paint
        fill = paint
        fillOpacity = isSelected ? Self.selectedFillOpacity : (isDark ? Self.darkFillOpacity : Self.lightFillOpacity)
    }

    var fillColor: Color { fill.color.opacity(fillOpacity) }
}

/// What a symbol or line of text is drawn in: a system hue, or one of the
/// calm greys. A value so presentation types stay `Equatable`.
enum LeoInk: Equatable, Sendable {
    case tint(LeoTint)
    case secondary
    case tertiary

    /// A selected row keeps contrast by going white; a grey keeps its
    /// semantic level, which the selection already adapts.
    func style(isSelected: Bool) -> AnyShapeStyle {
        switch self {
        case .tint(let tint): isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(tint.color)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        }
    }
}
