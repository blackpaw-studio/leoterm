import AppKit
import LeoKit

final class LeoPluginLoadingView: NSView {
    private let spinner = NSProgressIndicator()
    private let message = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

    init(loading: LeoPluginNode.Loading) {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        let stack = NSStackView(views: [spinner, message])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        update(loading: loading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(loading: LeoPluginNode.Loading) {
        message.stringValue = loading.message ?? ""
        message.isHidden = (loading.message ?? "").isEmpty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Stop animating when off screen; no work for a hidden slot.
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
}
