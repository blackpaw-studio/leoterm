import AppKit
import SwiftUI

/// B-149: runs work once AppKit has laid out the sidebar list, so a scroll
/// in it sees the list's own size rather than the one before a change. A
/// view behind the list takes each request on its next layout, lays the
/// list out first, then runs it once; nothing runs on a layout without a
/// request (D-130: a refresh never scrolls).
@MainActor final class LeoListLayoutAnchor {
    /// The view behind the list, once made.
    fileprivate weak var view: LeoListLayoutAnchorView?
    /// The work for the next layout: the latest request wins.
    fileprivate var pending: (@MainActor () -> Void)?

    /// Runs `work` after the list's next layout: the window's own, or one
    /// it's asked for a turn later, after whatever change is under way --
    /// the display pass that would lay it out can come later still. Until
    /// the view behind the list is in a window, the request waits.
    func request(_ work: @escaping @MainActor () -> Void) {
        pending = work
        view?.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.view?.window?.layoutIfNeeded() }
    }

    fileprivate func runPending(behind view: NSView) {
        guard view.window != nil, let work = pending else { return }
        pending = nil
        LeoTerminalsViewport.tableScrollView(behind: view)?.layoutSubtreeIfNeeded()
        work()
    }
}

/// The view behind the sidebar list that its `LeoListLayoutAnchor` runs
/// from. It takes no part in hit testing.
struct LeoListLayoutAnchorBackdrop: NSViewRepresentable {
    let anchor: LeoListLayoutAnchor

    func makeNSView(context: Context) -> LeoListLayoutAnchorView { LeoListLayoutAnchorView() }

    func updateNSView(_ view: LeoListLayoutAnchorView, context: Context) {
        view.anchor = anchor
        anchor.view = view
        if anchor.pending != nil { view.needsLayout = true }
    }
}

final class LeoListLayoutAnchorView: NSView {
    fileprivate weak var anchor: LeoListLayoutAnchor?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, anchor?.pending != nil { needsLayout = true }
    }

    override func layout() {
        super.layout()
        anchor?.runPending(behind: self)
    }
}
