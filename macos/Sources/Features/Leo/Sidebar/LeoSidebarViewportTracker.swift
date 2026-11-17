import AppKit
import SwiftUI

/// B-413: which table rows of the sidebar list are on screen, so rows
/// scrolled off an edge can be told from rows in view. A finder behind the
/// list locates its scroll view; the clip view's bounds and frame (and the
/// table's own frame, as rows come and go) say when to measure again.
///
/// A row counts as in view when its vertical midpoint is inside what the
/// list shows (its clip view less any bar over it): a row cut in half at an
/// edge is in view once more than half of it shows.
@MainActor final class LeoSidebarViewportTracker: ObservableObject {
    /// The table's rows as last measured.
    struct Viewport: Equatable {
        let visibleRows: ClosedRange<Int>
        let numberOfRows: Int
    }

    /// Nil until the list's table is found and has rows on screen. Only
    /// republished when it changes, so scrolling inside a row's height
    /// doesn't redraw the sidebar.
    @Published private(set) var viewport: Viewport?

    fileprivate weak var finder: NSView?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Measures the list as it stands, finding it first if need be.
    func refresh() {
        attachIfNeeded()
        let measured = scrollView.flatMap(Self.viewport(of:))
        if measured != viewport { viewport = measured }
    }

    private func attachIfNeeded() {
        if let scrollView, scrollView.window != nil, scrollView.documentView is NSTableView { return }
        detach()
        guard let finder, let found = LeoTerminalsViewport.tableScrollView(behind: finder),
              let table = found.documentView as? NSTableView else { return }
        scrollView = found
        let clip = found.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        table.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let names: [(Notification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip),
            (NSView.frameDidChangeNotification, table),
        ]
        observers = names.map { name, view in
            // A turn later: these arrive during layout, which can be inside a
            // SwiftUI update, where publishing is not allowed.
            center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollView = nil
    }

    /// The rows of `scrollView`'s table whose midpoint shows in its
    /// unobscured bounds; nil when the table is empty or none does.
    static func viewport(of scrollView: NSScrollView) -> Viewport? {
        guard let table = scrollView.documentView as? NSTableView, table.numberOfRows > 0 else { return nil }
        let clip = scrollView.contentView
        let shown = table.convert(LeoTerminalsViewport.unobscuredBounds(of: clip), from: clip)
        let candidates = table.rows(in: shown)
        guard candidates.length > 0 else { return nil }
        let inView = (candidates.location ..< NSMaxRange(candidates)).filter { row in
            let mid = table.rect(ofRow: row).midY
            return mid >= shown.minY && mid <= shown.maxY
        }
        guard let first = inView.first, let last = inView.last else { return nil }
        return Viewport(visibleRows: first ... last, numberOfRows: table.numberOfRows)
    }
}

/// A view behind the sidebar list that its `LeoSidebarViewportTracker`
/// finds the list from. It takes no part in hit testing.
struct LeoSidebarViewportFinder: NSViewRepresentable {
    let tracker: LeoSidebarViewportTracker

    func makeNSView(context: Context) -> LeoSidebarViewportFinderView { LeoSidebarViewportFinderView() }

    func updateNSView(_ view: LeoSidebarViewportFinderView, context: Context) {
        view.tracker = tracker
        tracker.finder = view
    }
}

final class LeoSidebarViewportFinderView: NSView {
    weak var tracker: LeoSidebarViewportTracker?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { measureNextTurn() }
    }

    /// The list's table can arrive after this view lays out, so each layout
    /// looks again (cheap once found).
    override func layout() {
        super.layout()
        measureNextTurn()
    }

    private func measureNextTurn() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.tracker?.refresh() }
        }
    }
}
