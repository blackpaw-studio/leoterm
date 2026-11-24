import AppKit

/// A place on a dock edge for one pane's container (B-439): a split item's
/// view controller that hosts whichever container the layout puts there,
/// or none. Moving a pane moves its container, children and all, between
/// slots, so its views (text, undo, scroll, the browser's page) go along.
final class LeoDockSlotViewController: NSViewController {
    enum Column {
        /// Files' outline, leading.
        case outline
        /// The tab strip: Files' tabs, the Browser, or both.
        case strip
    }

    let edge: LeoDockEdge
    let column: Column
    private(set) var hosted: LeoRowPaneContainerViewController?

    init(edge: LeoDockEdge, column: Column) {
        self.edge = edge
        self.column = column
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.setAccessibilityElement(false)
        // Not through `host`: nothing may collapse or expand the slot's own
        // split item while the split view is loading it.
        if let hosted { embed(hosted.view) }
    }

    /// Whether the hosted container has something to show.
    var isPaneOpen: Bool { hosted?.activeChild.isPaneOpen ?? false }

    /// Hosts `container` in place of what it held. The container must have
    /// left its last slot first (`host(nil)` there).
    func host(_ container: LeoRowPaneContainerViewController?) {
        guard container !== hosted else { return }
        if let hosted {
            if hosted.isViewLoaded { hosted.view.removeFromSuperview() }
            hosted.removeFromParent()
        }
        hosted = container
        guard let container else { return }
        addChild(container)
        if isViewLoaded { embed(container.view) }
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
}
