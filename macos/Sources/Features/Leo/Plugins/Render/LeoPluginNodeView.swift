import AppKit
import LeoKit

/// Draws a slot root (one component, or several stacked) and applies the keyed
/// tree diff on every re-render, so lists keep selection and scroll, forms
/// keep what was typed, and only what changed is touched.
final class LeoPluginNodeView: NSView {
    private let emitter: LeoPluginActionEmitter
    private(set) var nodes: [LeoPluginNode] = []
    private var children: [NSView] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var lastReportedHeight: CGFloat?
    /// Fires with the scrolled content's laid-out height (nil when the content scrolls or sizes itself, e.g. a list),
    /// so a host can grow to fit it.
    var onPreferredHeightChange: (CGFloat?) -> Void = { _ in }

    /// A lone form scrolls like a stacked slot, so a tall form is reachable inside a fixed-height pane.
    static func scrolls(_ nodes: [LeoPluginNode]) -> Bool {
        if nodes.count > 1 { return true }
        if case .form? = nodes.first { return true }
        return false
    }

    init(emitter: LeoPluginActionEmitter) {
        self.emitter = emitter
        super.init(frame: .zero)
        stack.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stackFrameChanged), name: NSView.frameDidChangeNotification, object: stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The first render replaces everything; later ones apply the diff.
    func render(_ newNodes: [LeoPluginNode]) {
        defer { nodes = newNodes }
        for op in LeoPluginTreeDiff.diff(old: nodes, new: newNodes) {
            switch op {
            case .replaceRoot(let all):
                rebuild(all)
            case .replaceNode(let index, let node):
                if Self.scrolls(nodes) != Self.scrolls(newNodes) { rebuild(newNodes) } else { replace(at: index, with: node, of: newNodes.count) }
            case .updateList(let index, let patch):
                if let list = children[safe: index] as? LeoPluginListView {
                    list.apply(patch: patch)
                } else if case .list = newNodes[index] {
                    replace(at: index, with: newNodes[index], of: newNodes.count)
                }
            }
        }
    }

    // MARK: Build

    private func rebuild(_ all: [LeoPluginNode]) {
        children.forEach { $0.removeFromSuperview() }
        scroll.removeFromSuperview()
        let embedded = all.count > 1
        children = all.map { makeView(for: $0, embedded: embedded) }
        guard Self.scrolls(all) else {
            reportPreferredHeight(nil)
            guard let only = children.first else { return }
            pin(only, in: self)
            return
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let document = LeoPluginFlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        for child in children {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // The document's height comes from the stack; its width and origin from the clip view.
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        pin(scroll, in: self)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @objc private func stackFrameChanged() {
        guard Self.scrolls(nodes) else { return }
        reportPreferredHeight(stack.frame.height)
    }

    private func reportPreferredHeight(_ height: CGFloat?) {
        guard height != lastReportedHeight else { return }
        lastReportedHeight = height
        onPreferredHeightChange(height)
    }

    private func replace(at index: Int, with node: LeoPluginNode, of count: Int) {
        guard children.indices.contains(index) else { return }
        if updateInPlace(children[index], with: node) { return }
        let old = children[index]
        let new = makeView(for: node, embedded: count > 1)
        if count > 1, let position = stack.arrangedSubviews.firstIndex(of: old) {
            stack.removeArrangedSubview(old)
            old.removeFromSuperview()
            stack.insertArrangedSubview(new, at: position)
            new.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            old.removeFromSuperview()
            pin(new, in: self)
        }
        children[index] = new
    }

    /// Same component kind: update the live view rather than replace it.
    private func updateInPlace(_ view: NSView, with node: LeoPluginNode) -> Bool {
        switch (view, node) {
        case (let v as LeoPluginListView, .list(let list)): v.apply(list: list)
        case (let v as LeoPluginDetailView, .detail(let detail)): v.update(detail: detail)
        case (let v as LeoPluginFormView, .form(let form)): v.update(form: form)
        case (let v as LeoPluginAccessoryView, .accessory(let accessory)): v.update(accessory: accessory)
        case (let v as LeoPluginTextBodyView, .text(let text)): v.update(text: text)
        case (let v as LeoPluginMeterView, .meter(let meter)): v.update(meter: meter)
        case (let v as LeoPluginEmptyStateView, .emptyState(let state)): v.update(state: state)
        case (let v as LeoPluginLoadingView, .loading(let loading)): v.update(loading: loading)
        case (let v as LeoPluginErrorView, .error(let error)): v.update(error: error)
        default: return false
        }
        return true
    }

    private func makeView(for node: LeoPluginNode, embedded: Bool) -> NSView {
        switch node {
        case .list(let list): LeoPluginListView(list: list, emitter: emitter, embedded: embedded)
        case .detail(let detail): LeoPluginDetailView(detail: detail, embedded: embedded)
        case .form(let form): LeoPluginFormView(form: form, emitter: emitter, embedded: embedded)
        case .accessory(let accessory): LeoPluginAccessoryView(accessory: accessory)
        case .text(let text): LeoPluginTextBodyView(text: text)
        case .meter(let meter): LeoPluginMeterView(meter: meter, style: .body)
        case .emptyState(let state): LeoPluginEmptyStateView(state: state, emitter: emitter)
        case .loading(let loading): LeoPluginLoadingView(loading: loading)
        case .error(let error): LeoPluginErrorView(error: error, emitter: emitter)
        }
    }

    private func pin(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
