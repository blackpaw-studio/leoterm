import AppKit
import Combine
import LeoKit
import SwiftUI

/// Draws one slot with the plugin renderers and keeps it current as the slot
/// store changes. Marks the plugin's slot visible while it is in a window.
final class LeoPluginSlotContentView: NSView {
    private let binding: LeoPluginSlotBinding
    private let nodeView: LeoPluginNodeView
    /// Whether the slot's first focusable view takes the keyboard (the palette
    /// page does, so Return and the arrows reach its list).
    private let takesFocus: Bool
    private var subscription: AnyCancellable?

    @MainActor init(binding: LeoPluginSlotBinding, takesFocus: Bool = false) {
        self.binding = binding
        self.takesFocus = takesFocus
        nodeView = LeoPluginNodeView(emitter: LeoPluginActionEmitter(
            mint: LeoPluginGestureMint(), handler: { action, gesture in binding.perform(action, gesture: gesture) }))
        super.init(frame: .zero)
        nodeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nodeView)
        NSLayoutConstraint.activate([
            nodeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nodeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nodeView.topAnchor.constraint(equalTo: topAnchor),
            nodeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        // `objectWillChange` fires before the change lands; the hop reads the new state.
        subscription = binding.host.slots.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor private func refresh() {
        nodeView.render(binding.nodes)
        focusIfNeeded()
    }

    /// Moves focus into the slot unless it is already inside it.
    @MainActor private func focusIfNeeded() {
        guard takesFocus, let window else { return }
        if let current = window.firstResponder as? NSView, current.isDescendant(of: self) { return }
        guard let target = Self.firstFocusable(in: nodeView) else { return }
        window.makeFirstResponder(target)
    }

    private static func firstFocusable(in view: NSView) -> NSView? {
        for child in view.subviews {
            if child.acceptsFirstResponder { return child }
            if let found = firstFocusable(in: child) { return found }
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let visible = window != nil
        let (host, id) = (binding.host, binding.key.pluginID)
        Task { @MainActor [weak self] in
            host.setSlotVisible(plugin: id, visible: visible)
            self?.focusIfNeeded()
        }
    }
}

/// The slot's content inside SwiftUI.
struct LeoPluginSlotContent: NSViewRepresentable {
    let binding: LeoPluginSlotBinding
    var takesFocus = false

    func makeNSView(context: Context) -> LeoPluginSlotContentView { LeoPluginSlotContentView(binding: binding, takesFocus: takesFocus) }
    func updateNSView(_ nsView: LeoPluginSlotContentView, context: Context) {}
}
