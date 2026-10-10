import AppKit
import Combine

/// A pane view a row keeps while it's off screen (B-274).
protocol LeoRowPaneChild: NSViewController {
    /// Whether it has anything to show: its split item collapses otherwise.
    var isPaneOpen: Bool { get }
    /// Back on screen: catches up with the disk, as becoming key does.
    func onShown()
}

/// The window's editor or browser split item (B-274). The item stays put;
/// inside it, the pane view of the row on screen is swapped in. Each row
/// keeps its own view controller, so its text, selection, scroll, undo and
/// outline expansion are there again when its row is shown again.
///
/// Only the child on screen sets the item's collapsed state; a hidden row
/// opening or closing its file changes nothing on screen.
final class LeoRowPaneContainerViewController: NSViewController {
    enum Role {
        case editor
        case browser
    }

    let role: Role
    private let panes: LeoRowPanes
    private let makeChild: (LeoRowPane) -> LeoRowPaneChild
    private var rowChildren: [ObjectIdentifier: LeoRowPaneChild] = [:]
    private var shown: LeoRowPaneChild?
    private var subscription: AnyCancellable?

    init(role: Role, panes: LeoRowPanes, makeChild: @escaping (LeoRowPane) -> LeoRowPaneChild) {
        self.role = role
        self.panes = panes
        self.makeChild = makeChild
        super.init(nibName: nil, bundle: nil)
        // Parented now, not when the view loads: a collapsed item's view
        // isn't loaded until it's shown, and the pane's own open is what
        // shows it.
        adopt(activeChild)
        // `@Published` sends before it stores: the new pane is the value.
        subscription = panes.$active.dropFirst().sink { [weak self] pane in self?.show(pane) }
    }

    required init?(coder: NSCoder) { nil }

    /// The pane view of the row on screen, made the first time it's asked for.
    var activeChild: LeoRowPaneChild { child(for: panes.active) }

    override func loadView() {
        view = NSView()
        view.setAccessibilityElement(false)
        // Not through `show`: collapsing or expanding its own split item
        // while the split view is loading it throws.
        if let shown { embed(shown.view) }
    }

    // MARK: - Switching

    private func show(_ pane: LeoRowPane) {
        let next = child(for: pane)
        prune(keeping: pane)
        guard next !== shown else { return }
        adopt(next)
        guard isViewLoaded else { return }
        embed(next.view)
        // Room is made as for any pane shown (D-036); its width is the one
        // the item had, not a fresh half-width opening (D-038).
        setLeoSplitItemCollapsed(!next.isPaneOpen)
        next.onShown()
    }

    /// `child` becomes the one on screen, in place of the last.
    private func adopt(_ child: LeoRowPaneChild) {
        if let shown {
            if shown.isViewLoaded { shown.view.removeFromSuperview() }
            shown.removeFromParent()
        }
        shown = child
        addChild(child)
    }

    private func embed(_ childView: NSView) {
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// A pane view's own request to collapse or show the item: only the
    /// one on screen gets it.
    func childRequestsCollapsed(_ child: NSViewController, _ collapsed: Bool, openingAtHalfWidth: Bool) {
        guard child === shown else { return }
        setLeoSplitItemCollapsed(collapsed, openingAtHalfWidth: openingAtHalfWidth)
    }

    // MARK: - Helpers

    private func child(for pane: LeoRowPane) -> LeoRowPaneChild {
        let id = ObjectIdentifier(pane)
        if let child = rowChildren[id] { return child }
        let child = makeChild(pane)
        rowChildren[id] = child
        return child
    }

    /// Lets go of the views of rows whose panes are gone.
    private func prune(keeping pane: LeoRowPane) {
        let live = Set((panes.all + [pane]).map(ObjectIdentifier.init))
        rowChildren = rowChildren.filter { live.contains($0.key) || $0.value === shown }
    }
}

extension NSSplitViewItem {
    /// Which side pane the item holds, if it's one (B-274).
    var leoPaneRole: LeoRowPaneContainerViewController.Role? {
        (viewController as? LeoRowPaneContainerViewController)?.role
    }
}
