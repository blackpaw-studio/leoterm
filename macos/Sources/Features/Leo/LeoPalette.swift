import SwiftUI

/// Single source of truth for Leo's status and chrome colors. Every Leo view
/// (sidebar, grid overlays, dead cells, banners) reads from here so a theming
/// or contrast pass touches one file. All values are semantic system colors and
/// therefore adapt to light/dark appearance automatically.
enum LeoPalette {
    // MARK: Status

    /// Agent process is running (daemon lifecycle) / output flowing.
    static let running: Color = .green
    /// Output actively flowing (cell activity signal).
    static let working: Color = .green
    /// Agent is booting (daemon lifecycle `starting`).
    static let starting: Color = .yellow
    /// Quiet, nothing happening.
    static let idle: Color = .secondary
    /// Agent is waiting on the user (bell). Amber, pulsing.
    static let needsYou: Color = .orange
    /// Process error or exit.
    static let error: Color = .red
    /// Daemon unreachable / agent stopped.
    static let offline: Color = .secondary

    // MARK: Chrome

    /// Baseline stroke around every grid cell.
    static let cellStroke: Color = Color.secondary.opacity(0.25)
    /// Stroke around the focused grid cell.
    static let focusedCellStroke: Color = Color.accentColor.opacity(0.8)
    /// Background tint of inline error banners.
    static let errorBanner: Color = Color.red.opacity(0.08)
    /// Hover highlight for interactive rows.
    static let rowHover: Color = Color.primary.opacity(0.06)
    /// Row highlight for the selected/focused entry.
    static let rowSelected: Color = Color.accentColor.opacity(0.18)

    /// Corner radius shared by every cell-shaped surface (live, dead, overlay).
    static let cellCornerRadius: CGFloat = 6
}
