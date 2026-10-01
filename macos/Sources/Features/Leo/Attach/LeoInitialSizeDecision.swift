import Foundation

/// Pure decisions for `TerminalController.leoApplyInitialSize`, run when a
/// Leo start screen gets its first content.
///
/// B-086: a window already on screen keeps its frame then (P1, P2) -- the
/// SwiftUI view's intrinsic size, read before it caught up with the new
/// surface, once shrank it. Only a window not yet shown is sized, from
/// the configured `window-width`/`window-height`, as `windowDidLoad`
/// sizes a window created with its surface.
///
/// No AppKit dependency -- takes plain values so it's directly testable.
enum LeoInitialSizeDecision {
    /// Whether the window may be sized: only while it has never been on
    /// screen. `isAwaitingPresentation` stays false once it has been shown,
    /// minimized or with its app hidden too, when `isVisible` is false.
    static func shouldSize(isVisible: Bool, isAwaitingPresentation: Bool) -> Bool {
        !isVisible && isAwaitingPresentation
    }

    /// The window's content size for a terminal of `initialSize` (what
    /// `window-width`/`window-height` give a surface): that, plus the
    /// sidebar and its divider beside it when the sidebar shows
    /// (`sidebarWidth` is nil when it's hidden). Nil when no size is
    /// configured.
    ///
    /// Beside the sidebar, the terminal gets at least
    /// `LeoSidebarSplitMetrics.contentMinimumWidth` (B-091): the sidebar's
    /// maximum leaves the content that much, so a narrower terminal would
    /// clamp the sidebar's stored width as the window opens.
    static func contentSize(initialSize: CGSize?, sidebarWidth: CGFloat?, dividerWidth: CGFloat) -> CGSize? {
        guard let initialSize else { return nil }
        guard let sidebarWidth else { return initialSize }
        let terminalWidth = max(initialSize.width, LeoSidebarSplitMetrics.contentMinimumWidth)
        return CGSize(width: terminalWidth + sidebarWidth + dividerWidth, height: initialSize.height)
    }
}
