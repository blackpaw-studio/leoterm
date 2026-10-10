import AppKit
import SwiftUI

/// The semantic system hues the sidebar's pills, chips and dots are drawn in.
/// A value (not a `Color`) so presentation types stay `Equatable` and tests
/// can name a tint without comparing colors.
enum LeoTint: Equatable, Sendable {
    case orange, red, green, gray, indigo, blue, cyan, purple, pink, mint

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
        case .pink: .systemPink
        case .mint: .systemMint
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A tinted fill's opacity: a little stronger on a dark background,
    /// where the same alpha reads fainter.
    static func fillOpacity(isDark: Bool) -> Double { isDark ? 0.20 : 0.15 }
}
