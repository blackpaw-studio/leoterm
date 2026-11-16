import LeoKit
import SwiftUI

/// Shared spacing for Settings views that draw their own chrome (banners,
/// sheets, pane notices). Form sections take the system's spacing.
enum LeoSettingsMetrics {
    /// Inside a list row or an attached bottom bar.
    static let rowPadding: CGFloat = 6
    /// Inside a row, strip or compact group.
    static let compactPadding: CGFloat = 8
    /// Inside a banner or a toolbar-like strip.
    static let groupPadding: CGFloat = 12
    /// Around a popover's or a pane's content.
    static let contentPadding: CGFloat = 16
    /// Around a sheet's content.
    static let sheetPadding: CGFloat = 20
    /// Around an empty or error state that fills a pane.
    static let panePadding: CGFloat = 24
    static let cornerRadius: CGFloat = 8
    /// A banner's tinted fill.
    static let bannerFillOpacity = 0.12
}

/// What a status reads as in Settings, in semantic system colours: the one
/// place that maps a state to a hue, so panes agree and dark mode follows.
enum LeoSettingsStatus {
    case success, warning, failure

    var tint: LeoTint {
        switch self {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    var color: Color { tint.color }

    /// The tinted fill behind a banner of this status.
    var bannerFill: Color { color.opacity(LeoSettingsMetrics.bannerFillOpacity) }
}
