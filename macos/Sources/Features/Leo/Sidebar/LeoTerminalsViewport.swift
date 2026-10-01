import AppKit
import SwiftUI

/// B-105: whether any part of the sidebar's Terminals section shows in
/// the list. The section is always the list's last, so that's whether
/// its last rows -- its header and terminals -- reach into what the list
/// shows. A finder behind the list locates its scroll view.
///
/// Neither the section's own row views nor probes in them can say this:
/// the list reuses a row's views for other rows (a probe lingers in an
/// agent's), and makes a row's views only when it next draws, so a row
/// just listed can be on screen with no views yet.
///
/// Read as the window's terminals are about to change (`snapshot`), so
/// it sees the list as it stood: by the time the sidebar sees the section
/// closed, the list has already dropped its rows and clamped its offset.
@MainActor final class LeoTerminalsViewport {
    /// The view behind the list.
    fileprivate weak var finder: NSView?
    /// The list's scroll view, once found.
    private weak var list: NSScrollView?

    /// The list's scroll view as of the last `snapshot`, if the section
    /// showed in it then; else nil.
    private(set) weak var shownIn: NSScrollView?

    /// `sectionRows` is how many rows the section has in the list as it
    /// stands: its header and terminals, or 0 when it isn't listed.
    func snapshot(sectionRows: Int) {
        if list?.window == nil { list = finder.flatMap(Self.tableScrollView(behind:)) }
        shownIn = list.flatMap { Self.showsLastRows(sectionRows, in: $0) ? $0 : nil }
    }

    /// The table's scroll view `view` sits behind: the nearest one, up
    /// its ancestors, whose frame meets its own.
    static func tableScrollView(behind view: NSView) -> NSScrollView? {
        guard view.window != nil else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        let ancestors = sequence(first: view.superview) { $0?.superview }.lazy.compactMap { $0 }
        return ancestors.lazy.compactMap { ancestor in
            tableScrollViews(in: ancestor).first { $0.convert($0.bounds, to: nil).intersects(frame) }
        }.first
    }

    /// The scroll views of tables in `view`, not looking inside any
    /// scroll view (a table's rows, a terminal's surface).
    private static func tableScrollViews(in view: NSView) -> [NSScrollView] {
        if let scrollView = view as? NSScrollView { return scrollView.documentView is NSTableView ? [scrollView] : [] }
        return view.subviews.flatMap(tableScrollViews(in:))
    }

    /// Whether any of the last `rows` rows of `scrollView`'s table shows
    /// in what it doesn't cover with a bar.
    static func showsLastRows(_ rows: Int, in scrollView: NSScrollView) -> Bool {
        guard rows > 0, let table = scrollView.documentView as? NSTableView, table.numberOfRows >= rows else { return false }
        let last = table.numberOfRows - 1
        let section = table.rect(ofRow: last - rows + 1).union(table.rect(ofRow: last))
        let clip = scrollView.contentView
        return table.convert(section, to: clip).intersects(unobscuredBounds(of: clip))
    }

    /// Scrolls `scrollView` to its very top, where the list launches --
    /// above the first section's header by the list's top margin -- without
    /// animation.
    static func scrollToTop(_ scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let topY = clip.isFlipped ? -clip.contentInsets.top : documentHeight + clip.contentInsets.top - clip.bounds.height
        let top = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: topY), size: clip.bounds.size))
        clip.scroll(to: top.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The clip view's bounds less its content insets: what a bar over the
    /// list (a titlebar, a footer) covers isn't on screen.
    static func unobscuredBounds(of clip: NSClipView) -> NSRect {
        let insets = clip.contentInsets
        let (minYInset, maxYInset) = clip.isFlipped ? (insets.top, insets.bottom) : (insets.bottom, insets.top)
        let bounds = clip.bounds
        return NSRect(
            x: bounds.minX + insets.left, y: bounds.minY + minYInset,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - minYInset - maxYInset)
        )
    }
}

/// A view behind the sidebar list that its `LeoTerminalsViewport` finds
/// the list from. It takes no part in hit testing.
struct LeoTerminalsViewportFinder: NSViewRepresentable {
    let viewport: LeoTerminalsViewport

    func makeNSView(context: Context) -> LeoTerminalsViewportFinderView { LeoTerminalsViewportFinderView() }

    func updateNSView(_ view: LeoTerminalsViewportFinderView, context: Context) { viewport.finder = view }
}

final class LeoTerminalsViewportFinderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
