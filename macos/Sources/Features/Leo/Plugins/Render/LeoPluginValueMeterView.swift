import AppKit
import LeoKit

/// A value `Meter` (apiVersion 2): label | capsule track | valueText on one
/// row, `detail` below at the label's x. Metrics follow
/// `docs/designs/usage-plugin/design.md`; the fill, VoiceOver text and tone
/// rules are `LeoPluginValueMeterPresentation`'s. VoiceOver reads the whole
/// meter as one level indicator.
final class LeoPluginValueMeterView: NSStackView {
    enum Style {
        /// Pane and palette bodies, and inside a Group.
        case regular
        /// A pane summary: one tight row, no detail.
        case summary

        var trackHeight: CGFloat { self == .regular ? 6 : 5 }
        var fontSize: CGFloat { self == .regular ? 13 : 11 }
        var labelColor: NSColor { self == .regular ? .labelColor : .secondaryLabelColor }
    }

    static let columnGap: CGFloat = 8
    static let detailGap: CGFloat = 2
    /// The narrowest a track gets before the label gives way.
    static let minimumTrackWidth: CGFloat = 48
    /// Share of the meter's width the label column may take.
    static let labelWidthCap: CGFloat = 0.4

    private let style: Style
    private let row = NSStackView()
    let label: NSTextField
    private let track: LeoPluginValueMeterTrackView
    private let valueText: NSTextField
    private let detail = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private(set) var meter: LeoPluginNode.ValueMeter
    private var columnConstraint: NSLayoutConstraint?

    /// The label's own width: what a shared label column is sized from.
    var naturalLabelWidth: CGFloat { ceil(label.intrinsicContentSize.width) }

    /// A label column shared with other meters (the widest label in the
    /// slot), so tracks line up. Still capped at 40% of the meter; nil sizes
    /// the label to its own text.
    var labelColumnWidth: CGFloat? {
        didSet {
            guard labelColumnWidth != oldValue else { return }
            columnConstraint?.isActive = false
            columnConstraint = labelColumnWidth.map { width in
                let constraint = label.widthAnchor.constraint(equalToConstant: width)
                // Above the label's hugging, below the required 40% cap.
                constraint.priority = Self.columnPriority
                constraint.isActive = true
                return constraint
            }
        }
    }

    /// True when valueText shows fewer points than its text needs (design.md:
    /// it never truncates). Half a point absorbs layout rounding.
    var isValueTextTruncated: Bool {
        !valueText.isHidden && valueText.frame.width + Self.layoutRounding < valueText.intrinsicContentSize.width
    }

    private static let layoutRounding: CGFloat = 0.5
    private static let columnPriority = NSLayoutConstraint.Priority(740)
    private static let labelHugging = NSLayoutConstraint.Priority(730)

    init(meter: LeoPluginNode.ValueMeter, style: Style) {
        self.meter = meter
        self.style = style
        label = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: style.fontSize), color: style.labelColor)
        valueText = LeoPluginRenderStyle.label("", font: .monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular))
        track = LeoPluginValueMeterTrackView(height: style.trackHeight)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Self.detailGap
        buildRow()
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        if style == .regular { addArrangedSubview(detail) }
        [label, valueText, detail].forEach { $0.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 100))
        update(meter: meter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildRow() {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.columnGap
        [label, track, valueText].forEach(row.addArrangedSubview)
        // valueText never truncates; the label gives way first, down to the track's minimum.
        valueText.alignment = .right
        valueText.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueText.setContentHuggingPriority(.required, for: .horizontal)
        let widest = ("100%" as NSString).size(withAttributes: [.font: valueText.font as Any]).width
        valueText.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(widest)).isActive = true
        // Hugs against the track, but gives way to a shared column width.
        label.setContentHuggingPriority(Self.labelHugging, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let minimum = track.widthAnchor.constraint(greaterThanOrEqualToConstant: style == .summary ? 56 : Self.minimumTrackWidth)
        minimum.priority = .defaultHigh
        minimum.isActive = true
        if style == .summary { track.widthAnchor.constraint(equalToConstant: 56).isActive = true }
        let cap = label.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: Self.labelWidthCap)
        cap.isActive = style == .regular
    }

    func update(meter: LeoPluginNode.ValueMeter) {
        self.meter = meter
        let presentation = LeoPluginValueMeterPresentation(meter)
        label.stringValue = meter.label
        valueText.stringValue = meter.valueText ?? ""
        valueText.isHidden = (meter.valueText ?? "").isEmpty
        valueText.font = .monospacedDigitSystemFont(ofSize: style.fontSize, weight: presentation.emphasizesValueText ? .semibold : .regular)
        detail.stringValue = meter.detail ?? ""
        detail.isHidden = style == .summary || (meter.detail ?? "").isEmpty
        track.presentation = presentation
        toolTip = presentation.accessibilityLabel
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(NSNumber(value: presentation.accessibilityPercent))
    }
}

/// The capsule track and its toned fill, drawn with layers so a value change
/// can animate the fill width (not under Reduce Motion).
final class LeoPluginValueMeterTrackView: NSView {
    private static let animationDuration: CFTimeInterval = 0.2

    var presentation: LeoPluginValueMeterPresentation? {
        didSet {
            guard presentation != oldValue else { return }
            applyColors()
            layoutFill(animated: oldValue != nil)
        }
    }

    private let height: CGFloat
    private let fill = CALayer()

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = height / 2
        fill.cornerRadius = height / 2
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    override func layout() {
        super.layout()
        layoutFill(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func accessibilityDisplayChanged() { applyColors() }

    private func applyColors() {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (increaseContrast ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).cgColor
            fill.backgroundColor = presentation.map { LeoPluginRenderStyle.color(for: $0.tone).cgColor }
        }
    }

    private func layoutFill(animated: Bool) {
        let width = presentation?.fillWidth(trackWidth: Double(bounds.width), trackHeight: Double(bounds.height)) ?? 0
        CATransaction.begin()
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.setDisableActions(!shouldAnimate)
        if shouldAnimate {
            CATransaction.setAnimationDuration(Self.animationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        fill.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: bounds.height)
        CATransaction.commit()
    }
}
