import AppKit
import SwiftUI

/// Where the sidebar split sits against the window's titlebar, per
/// `macos-titlebar-style` (B-074).
///
/// - `native`, `transparent` (the default) and `tabs` keep a titled window
///   without a full-size content view: the titlebar and its window buttons
///   sit above the content, so the split stays inside the safe area and the
///   sidebar header clears them by `LeoSidebarChromeMetrics.topInset`
///   (D-122).
/// - `hidden` (`HiddenTitlebarTerminalWindow`) uses a full-size content view
///   and hides the titlebar container and all three window buttons. Its
///   `contentLayoutRect` override doesn't reach the safe area, though: the
///   theme frame still reports the 32 pt titlebar as a top inset, and the
///   system sidebar's glass wrapper adds 10 pt of its own, so the header
///   landed 52 pt under an empty strip. Nothing is drawn there, so the split
///   and the sidebar extend into it, as Ghostty's terminal content does: the
///   header takes the top strip with only its own inset, rather than keeping
///   an empty band for buttons that aren't shown.
enum LeoTitlebarInsets {
    /// The top safe-area edges the sidebar split and its sidebar ignore in
    /// `window`.
    ///
    /// Keyed on the window rather than the live config: the titlebar style
    /// is fixed when the window is built, and a config reload only affects
    /// new windows.
    static func splitIgnoredEdges(in window: NSWindow?) -> Edge.Set {
        window is HiddenTitlebarTerminalWindow ? .top : []
    }

    /// Where the side panes' (the workspace browser's and the editor's)
    /// header rows start below the split's top edge: the sidebar header's
    /// inset, so all three headers share one line (D-258). The split's top
    /// edge is the window's under the hidden style (B-100) and the
    /// titlebar's bottom edge under the titled ones, so the one inset puts
    /// the close glyphs the same room under either (B-154).
    static var sidePaneHeaderTopInset: CGFloat { LeoSidebarChromeMetrics.topInset }

    /// Centres `control`, one of `pane`'s header controls, on a sidebar
    /// header row (`LeoSidebarChromeMetrics.headerRowHeight`) starting
    /// `inset` below the pane's top edge. The header's own controls are
    /// centred on one line, so the whole header follows; an empty first
    /// row takes up the room above it. The control takes the row's (even)
    /// height: an odd-height frame centred on a whole-point line snaps half
    /// a point off where layout rounds to whole points (B-153).
    @MainActor
    static func insetHeader(of pane: NSStackView, at inset: CGFloat, centring control: NSView) {
        let spacer = NSView()
        spacer.setAccessibilityElement(false)
        pane.insertArrangedSubview(spacer, at: 0)
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalTo: pane.widthAnchor),
            control.heightAnchor.constraint(equalToConstant: LeoSidebarChromeMetrics.headerRowHeight),
            control.centerYAnchor.constraint(equalTo: pane.topAnchor, constant: inset + LeoSidebarChromeMetrics.headerRowHeight / 2),
        ])
    }
}
