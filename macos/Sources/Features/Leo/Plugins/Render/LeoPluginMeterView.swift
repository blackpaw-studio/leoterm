import AppKit
import LeoKit

/// A horizontal bar of toned segments, with an optional label after it.
/// In a pane summary the bar is a fixed 56 × 5 pt; in a body it fills the
/// width. Segment layout is `LeoPluginMeterGeometry`'s.
final class LeoPluginMeterView: NSStackView {
    enum Style { case summary, body }

    private let bar: LeoPluginMeterBarView
    private let label = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let style: Style

    init(meter: LeoPluginNode.Meter, style: Style) {
        self.style = style
        bar = LeoPluginMeterBarView(style: style)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        addArrangedSubview(bar)
        addArrangedSubview(label)
        label.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentHuggingPriority(style == .summary ? .required : .defaultLow, for: .horizontal)
        update(meter: meter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(meter: LeoPluginNode.Meter) {
        bar.meter = meter
        label.stringValue = meter.label ?? ""
        label.isHidden = (meter.label ?? "").isEmpty
        toolTip = meter.help
    }
}

/// The bar itself: a quiet track with the segments drawn over it.
final class LeoPluginMeterBarView: NSView {
    var meter: LeoPluginNode.Meter? { didSet { needsDisplay = true } }
    private let style: LeoPluginMeterView.Style

    init(style: LeoPluginMeterView.Style) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .summary: LeoPluginMeterGeometry.summarySize
        case .body: NSSize(width: NSView.noIntrinsicMetric, height: LeoPluginMeterGeometry.bodyHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        guard let meter else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        for bar in LeoPluginMeterGeometry.bars(meter.segments, max: meter.max, width: bounds.width) {
            LeoPluginRenderStyle.color(for: bar.tone).setFill()
            NSRect(x: bounds.minX + bar.x, y: bounds.minY, width: bar.width, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
