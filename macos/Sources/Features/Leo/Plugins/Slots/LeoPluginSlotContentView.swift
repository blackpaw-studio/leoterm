import AppKit
import Combine
import LeoKit
import SwiftUI

/// Draws one slot with the plugin renderers and keeps it current as the slot
/// store changes. Marks the plugin's slot visible while it is in a window.
final class LeoPluginSlotContentView: NSView {
    private let binding: LeoPluginSlotBinding
    private let nodeView: LeoPluginNodeView
    private var subscription: AnyCancellable?

    @MainActor init(binding: LeoPluginSlotBinding) {
        self.binding = binding
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

    @MainActor private func refresh() { nodeView.render(binding.nodes) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let visible = window != nil
        let (host, id) = (binding.host, binding.key.pluginID)
        Task { @MainActor in host.setSlotVisible(plugin: id, visible: visible) }
    }
}

/// The slot's content inside SwiftUI.
struct LeoPluginSlotContent: NSViewRepresentable {
    let binding: LeoPluginSlotBinding

    func makeNSView(context: Context) -> LeoPluginSlotContentView { LeoPluginSlotContentView(binding: binding) }
    func updateNSView(_ nsView: LeoPluginSlotContentView, context: Context) {}
}
