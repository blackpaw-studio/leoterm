import AppKit
import LeoKit

/// A small symbol + short text chip. `help` becomes the tooltip.
final class LeoPluginAccessoryView: NSStackView {
    private(set) var accessory: LeoPluginNode.Accessory

    init(accessory: LeoPluginNode.Accessory) {
        self.accessory = accessory
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        alignment = .centerY
        setContentHuggingPriority(.required, for: .horizontal)
        update(accessory: accessory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(accessory: LeoPluginNode.Accessory) {
        self.accessory = accessory
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let color = LeoPluginRenderStyle.nsColor(for: LeoPluginRenderStyle.ink(for: accessory.color))
        if let image = LeoPluginRenderStyle.symbol(accessory.sfSymbol, pointSize: 11, weight: .medium) {
            let view = NSImageView(image: image)
            view.contentTintColor = color
            addArrangedSubview(view)
        }
        if !accessory.text.isEmpty {
            addArrangedSubview(LeoPluginRenderStyle.label(
                accessory.text, font: .systemFont(ofSize: 11, weight: .medium), color: color))
        }
        toolTip = accessory.help
    }
}
