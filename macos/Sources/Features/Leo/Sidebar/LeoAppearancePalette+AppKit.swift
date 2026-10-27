import AppKit
import SwiftUI
import LeoKit

/// The Mac's shade for each palette name: the system colors, which already
/// adapt to light, dark and increased contrast.
extension LeoAppearanceColor {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}
