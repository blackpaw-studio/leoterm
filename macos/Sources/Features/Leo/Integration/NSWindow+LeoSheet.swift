import AppKit

extension NSWindow {
    /// Presents `controller` as a sheet on this window. Terminal windows set
    /// `contentView` directly and never a `contentViewController`, so
    /// `contentViewController?.presentAsSheet(_:)` silently no-ops on them
    /// (B-284). This anchors on a throwaway view controller whose `.view` IS
    /// the window's content view, so `presentAsSheet` still finds the window.
    /// Returns false when the window has no content view to anchor on.
    @discardableResult
    func presentLeoSheet(_ controller: NSViewController) -> Bool {
        guard let contentView else { return false }
        let anchor = NSViewController()
        anchor.view = contentView
        anchor.presentAsSheet(controller)
        return true
    }
}
