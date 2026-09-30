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
}
