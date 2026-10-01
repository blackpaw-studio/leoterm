import AppKit
import SwiftUI

/// B-105: whether any part of the sidebar's Terminals section shows in
/// the list, read from probes behind its header and rows. A row on screen
/// always has its view in the list, so with no probe in a window the
/// section isn't on screen; a probe's frame decides for a row the list
/// keeps just off screen.
///
/// Read as the window's terminals are about to change (`snapshot`), so
/// it sees the list as it stood: by the time the sidebar sees the section
/// closed, the list has already dropped its rows and clamped its offset.
@MainActor final class LeoTerminalsViewport {
    private let probes = NSHashTable<NSView>.weakObjects()

    /// The list's scroll view as of the last `snapshot`, if the section
    /// showed in it then; else nil.
    private(set) weak var shownIn: NSScrollView?

    func register(_ probe: NSView) { probes.add(probe) }

    func snapshot() {
        shownIn = probes.allObjects.lazy.compactMap(Self.scrollViewShowing).first
    }

    /// The scroll view `probe` shows in, if any part of it does.
    static func scrollViewShowing(_ probe: NSView) -> NSScrollView? {
        guard probe.window != nil, !probe.isHiddenOrHasHiddenAncestor,
              let scrollView = probe.enclosingScrollView else { return nil }
        let clip = scrollView.contentView
        return probe.convert(probe.bounds, to: clip).intersects(unobscuredBounds(of: clip)) ? scrollView : nil
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
    private static func unobscuredBounds(of clip: NSClipView) -> NSRect {
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

/// A view behind a Terminals header or row that registers with the
/// window's `LeoTerminalsViewport`. It takes no part in hit testing.
struct LeoTerminalsViewportProbe: NSViewRepresentable {
    let viewport: LeoTerminalsViewport

    func makeNSView(context: Context) -> LeoTerminalsViewportProbeView {
        let view = LeoTerminalsViewportProbeView()
        viewport.register(view)
        return view
    }

    func updateNSView(_ view: LeoTerminalsViewportProbeView, context: Context) { viewport.register(view) }
}

final class LeoTerminalsViewportProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func leoProbesTerminalsViewport(_ viewport: LeoTerminalsViewport) -> some View {
        background(LeoTerminalsViewportProbe(viewport: viewport).accessibilityHidden(true))
    }
}
