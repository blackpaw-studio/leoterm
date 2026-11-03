import LeoFeatures
import UIKit

/// The thin progress bar under an agent's subtitle, in the detail and in the
/// chat panel: a track and a fill. Determinate fills to the fraction, an
/// indeterminate bar slides (still under Reduce Motion), stale is dashed and
/// dim, failed is full and red.
final class TaskBarView: UIView {
    static let height: CGFloat = 3
    private let fill = CALayer()
    private var style: AgentProgress.Style = .indeterminate
    /// What the running slide animation was built for; it restarts only when this changes.
    private var animated: (style: AgentProgress.Style, width: CGFloat)?

    /// `usesFrames`: the owner positions it by frame (a list cell); otherwise it sizes itself with Auto Layout.
    init(usesFrames: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = Self.height / 2
        layer.masksToBounds = true
        layer.addSublayer(fill)
        if !usesFrames {
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        }
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ style: AgentProgress.Style) {
        self.style = style
        setNeedsLayout()
        layoutIfNeeded()
        updateAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        fill.cornerRadius = Self.height / 2
        let (fraction, color): (CGFloat, UIColor) = switch style {
        case .determinate(let value): (CGFloat(min(max(value, 0), 1)), .tintColor)
        case .indeterminate: (0.34, .tintColor)
        case .stale(let value): (CGFloat(value ?? 1), .tintColor.withAlphaComponent(0.45))
        case .failed: (1, .systemRed)
        }
        fill.frame = CGRect(x: 0, y: 0, width: width * fraction, height: bounds.height)
        fill.backgroundColor = color.resolvedColor(with: traitCollection).cgColor
        updateAnimation()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        guard case .indeterminate = style, window != nil, bounds.width > 0 else {
            fill.removeAnimation(forKey: "slide")
            animated = nil
            return
        }
        // Layout runs often (every list update); only a new style or width rebuilds it.
        let wanted = (style: style, width: bounds.width)
        if let animated, animated.style == wanted.style, animated.width == wanted.width, fill.animation(forKey: "slide") != nil { return }
        animated = wanted
        fill.removeAnimation(forKey: "slide")
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -fill.bounds.width / 2
        slide.toValue = bounds.width + fill.bounds.width / 2
        slide.duration = 1.5
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(slide, forKey: "slide")
    }
}

/// An Agents-list or detail row with a bar under its text. The bar lines up
/// with the text (the separator guide) and sits at the cell's bottom; the
/// content configuration leaves room for it.
final class ProgressListCell: UICollectionViewListCell {
    static let barReserve: CGFloat = 12
    private static let barBottomInset: CGFloat = 10
    private let bar = TaskBarView(usesFrames: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The cell, not its contentView: the list cell drops foreign contentView subviews.
        addSubview(bar)
        bar.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// By frame (cell coordinates): the bar starts where the text does (the separator's leading edge) and runs to the
    /// content's trailing margin. Auto Layout against the list cell's guides left it at the origin.
    override func layoutSubviews() {
        super.layoutSubviews()
        let leading = separatorLayoutGuide.layoutFrame.minX
        let trailing = contentView.convert(contentView.layoutMarginsGuide.layoutFrame, to: self).maxX
        bar.frame = CGRect(
            x: leading, y: bounds.maxY - Self.barBottomInset - TaskBarView.height,
            width: max(trailing - leading, 0), height: TaskBarView.height
        )
        bringSubviewToFront(bar)
    }

    /// Shows `style` under the text, or hides the bar when nil.
    func showBar(_ style: AgentProgress.Style?, in content: inout UIListContentConfiguration) {
        bar.isHidden = style == nil
        if let style {
            bar.apply(style)
            content.directionalLayoutMargins.bottom += Self.barReserve
            setNeedsLayout()
        }
    }
}
