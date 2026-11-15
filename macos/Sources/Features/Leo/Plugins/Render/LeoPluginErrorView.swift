import AppKit
import LeoKit

/// Message plus a Retry button that emits the error's retry action.
final class LeoPluginErrorView: NSView {
    private let emitter: LeoPluginActionEmitter
    private var retry: LeoPluginAction
    private let message = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lines: 6)

    init(error: LeoPluginNode.ErrorState, emitter: LeoPluginActionEmitter) {
        self.emitter = emitter
        self.retry = error.retry
        super.init(frame: .zero)
        let icon = NSImageView(image: LeoPluginRenderStyle.symbol("exclamationmark.triangle", pointSize: 26, weight: .light) ?? NSImage())
        icon.contentTintColor = LeoTint.orange.nsColor
        message.alignment = .center
        let button = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        button.image = LeoPluginRenderStyle.symbol("arrow.clockwise", pointSize: 12)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [icon, message, button])
        stack.orientation = .vertical
        stack.spacing = 8
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
        update(error: error)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(error: LeoPluginNode.ErrorState) {
        retry = error.retry
        message.stringValue = error.message
    }

    @objc private func retryTapped() { emitter.emit(retry, origin: .click) }
}
