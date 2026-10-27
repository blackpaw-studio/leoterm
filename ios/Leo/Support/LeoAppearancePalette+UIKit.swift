import LeoKit
import UIKit

extension LeoAppearanceColor {
    /// The palette name as this app's system color, which adapts to light
    /// and dark on its own.
    var uiColor: UIColor {
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
}
