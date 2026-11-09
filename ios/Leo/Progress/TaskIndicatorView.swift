import LeoKit
import UIKit

/// The Agents list's small circular task indicator (trailing accessory):
/// the system spinner when indeterminate, a pie for a determinate task
/// (UIKit has no circular determinate view), the same pie muted for a stale
/// task, and a red glyph for a failure. Under Reduce Motion the spinner
/// shows its spokes without turning.
final class TaskIndicatorView: UIView {
    static let size: CGFloat = 20
    private static let ringWidth: CGFloat = 1.5
    private static let wedgeInset: CGFloat = 3.5
    private static let mutedAlpha: CGFloat = 0.45

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let ring = CAShapeLayer()
    private let wedge = CAShapeLayer()
    private let glyph = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private var indicator: LeoTaskIndicator?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isAccessibilityElement = false
        spinner.hidesWhenStopped = false
        spinner.frame = bounds
        glyph.tintColor = .systemRed
        glyph.contentMode = .scaleAspectFit
        glyph.frame = bounds
        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        wedge.strokeColor = nil
        for view in [spinner, glyph] { addSubview(view) }
        for layer in [ring, wedge] { self.layer.addSublayer(layer) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func reduceMotionChanged() { refreshSpinner() }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.size, height: Self.size) }

    func apply(_ indicator: LeoTaskIndicator) {
        self.indicator = indicator
        let isSpinner: Bool
        let fraction: Double?
        var isMuted = false
        switch indicator {
        case .progress(let value):
            fraction = value
            isSpinner = value == nil
        case .stalled(let value):
            fraction = value ?? 0
            isSpinner = false
            isMuted = true
        case .failed:
            fraction = nil
            isSpinner = false
        }
        let isGlyph: Bool = if case .failed = indicator { true } else { false }
        spinner.isHidden = !isSpinner
        glyph.isHidden = !isGlyph
        ring.isHidden = isSpinner || isGlyph
        wedge.isHidden = ring.isHidden
        layer.opacity = 1
        refreshSpinner()
        if let fraction, !ring.isHidden {
            ringAndWedge(fraction: fraction, isMuted: isMuted)
        }
    }

    private func refreshSpinner() {
        guard !spinner.isHidden else { return spinner.stopAnimating() }
        if UIAccessibility.isReduceMotionEnabled { spinner.stopAnimating() } else { spinner.startAnimating() }
    }

    private func ringAndWedge(fraction: Double, isMuted: Bool) {
        let color = (isMuted ? UIColor.secondaryLabel : UIColor.tintColor).resolvedColor(with: traitCollection)
        let center = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let ringRadius = (Self.size - Self.ringWidth) / 2
        ring.path = UIBezierPath(arcCenter: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        ring.strokeColor = color.cgColor
        let radius = Self.size / 2 - Self.wedgeInset
        let clamped = min(max(fraction, 0), 1)
        let path = UIBezierPath()
        if clamped > 0 {
            path.move(to: center)
            let start = -CGFloat.pi / 2
            path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + CGFloat(clamped) * .pi * 2, clockwise: true)
            path.close()
        }
        wedge.path = path.cgPath
        wedge.fillColor = color.cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if let indicator { apply(indicator) }
    }
}
