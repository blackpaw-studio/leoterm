import AppKit

/// The agent window's toolbar height, read from the window rather than
/// assumed: the toolbar grows with its subtitle and a full-screen window
/// releases it at rest, so a fixed titlebar inset left a 52 pt band there.
/// The glass sidebar and the side panes' headers extend under the toolbar
/// (their split ignores the top safe area), so each takes this much, plus
/// the chrome's own gap, before its first row.
@MainActor
final class LeoToolbarInset: ObservableObject {
    /// The gap between the window's top edge and the content layout rect's
    /// top: 0 while the window shows no toolbar.
    @Published private(set) var height: CGFloat

    /// Whether the window is in native full screen: the terminal then
    /// ignores the top safe area too, which still holds the hidden toolbar.
    @Published private(set) var isFullScreen = false

    init(height: CGFloat = 0) {
        self.height = height
    }

    /// Where a header's first row starts below the window's top edge.
    var headerTop: CGFloat { Self.headerTop(forHeight: height) }

    nonisolated static func headerTop(forHeight height: CGFloat) -> CGFloat { height + LeoSidebarChromeMetrics.topInset }

    /// The toolbar's height given the window's content view height and the
    /// top of its content layout rect (both in window coordinates).
    nonisolated static func height(contentHeight: CGFloat, contentLayoutMaxY: CGFloat) -> CGFloat {
        max(0, contentHeight - contentLayoutMaxY)
    }

    /// In native full screen the toolbar is auto-hidden at rest and
    /// overlays the content when revealed, so nothing is reserved for it
    /// (`contentLayoutRect` still excludes it, which left a blank band).
    nonisolated static func measure(isFullScreen: Bool, contentHeight: CGFloat, contentLayoutMaxY: CGFloat) -> CGFloat {
        isFullScreen ? 0 : height(contentHeight: contentHeight, contentLayoutMaxY: contentLayoutMaxY)
    }

    func update(from window: NSWindow) {
        guard let content = window.contentView else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if isFullScreen != self.isFullScreen { self.isFullScreen = isFullScreen }
        let measured = Self.measure(
            isFullScreen: isFullScreen, contentHeight: content.frame.height,
            contentLayoutMaxY: window.contentLayoutRect.maxY)
        if measured != height { height = measured }
    }
}
