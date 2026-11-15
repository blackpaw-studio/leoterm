import AppKit
import LeoKit

/// A pane summary: its `Text`, `Meter` and `Accessory` nodes in one row, each
/// drawn by the same view the body uses (the meter at its 56 × 5 pt summary
/// size). Any other component is not part of a summary and is skipped; the
/// manager already refuses such a render, so none arrives here.
final class LeoPluginSummaryRowView: NSStackView {
    init(nodes: [LeoPluginNode]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        setContentHuggingPriority(.required, for: .horizontal)
        update(nodes: nodes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(nodes: [LeoPluginNode]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for node in nodes {
            switch node {
            case .text(let text): addArrangedSubview(LeoPluginTextView(text: text))
            case .meter(let meter): addArrangedSubview(LeoPluginMeterView(meter: meter, style: .summary))
            case .accessory(let accessory): addArrangedSubview(LeoPluginAccessoryView(accessory: accessory))
            case .list, .detail, .form, .emptyState, .loading, .error: continue
            }
        }
    }
}

/// What a summary shows in place of its row when the render failed: a "!"
/// with the error as its tooltip.
final class LeoPluginSummaryErrorView: NSStackView {
    init(message: String) {
        super.init(frame: .zero)
        let glyph = NSImageView(image: LeoPluginRenderStyle.symbol("exclamationmark.triangle.fill", pointSize: 11) ?? NSImage())
        glyph.contentTintColor = .systemOrange
        addArrangedSubview(glyph)
        toolTip = message
        setAccessibilityLabel("Summary failed: \(message)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
