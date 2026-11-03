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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = Self.height / 2
        layer.masksToBounds = true
        layer.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
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
        fill.removeAnimation(forKey: "slide")
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
            return
        }
        guard fill.animation(forKey: "slide") == nil else { return }
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
    private let bar = TaskBarView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: separatorLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        bar.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `style` under the text, or hides the bar when nil.
    func showBar(_ style: AgentProgress.Style?, in content: inout UIListContentConfiguration) {
        bar.isHidden = style == nil
        if let style {
            bar.apply(style)
            content.directionalLayoutMargins.bottom += Self.barReserve
        }
    }
}
