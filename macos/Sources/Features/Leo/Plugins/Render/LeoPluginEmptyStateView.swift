import AppKit
import LeoKit

final class LeoPluginEmptyStateView: NSView {
    private let emitter: LeoPluginActionEmitter
    private var actions: [LeoPluginLabeledAction] = []
    private let stack = NSStackView()

    init(state: LeoPluginNode.EmptyState, emitter: LeoPluginActionEmitter) {
        self.emitter = emitter
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: LeoPluginRenderStyle.gutter),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -LeoPluginRenderStyle.gutter),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        update(state: state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(state: LeoPluginNode.EmptyState) {
        actions = state.actions
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let image = LeoPluginRenderStyle.symbol(state.sfSymbol, pointSize: 28, weight: .light) {
            let view = NSImageView(image: image)
            view.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(view)
            stack.setCustomSpacing(10, after: view)
        }
        stack.addArrangedSubview(LeoPluginRenderStyle.label(state.title, font: .systemFont(ofSize: 14, weight: .semibold)))
        if let message = state.message, !message.isEmpty {
            let label = LeoPluginRenderStyle.label(message, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lines: 4)
            label.alignment = .center
            stack.addArrangedSubview(label)
        }
        let entries = LeoPluginActionPresentation.entries(for: state.actions)
        if let primary = entries.first {
            let button = LeoPluginRenderStyle.actionButton(primary, target: self, action: #selector(run(_:)))
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(12, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        }
        for entry in entries.dropFirst() {
            let button = LeoPluginRenderStyle.actionButton(entry, target: self, action: #selector(run(_:)))
            button.bezelStyle = .inline
            stack.addArrangedSubview(button)
        }
    }

    @objc private func run(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        emitter.emit(actions[sender.tag].action, origin: .click)
    }
}
