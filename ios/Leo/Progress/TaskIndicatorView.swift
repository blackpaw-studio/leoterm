import LeoKit
import UIKit

/// The Agents list's small circular task indicator (trailing accessory):
/// a static pie for a determinate task (UIKit has no circular determinate
/// view), the same pie muted for a stale task, and a red glyph for a failure.
/// An indeterminate task has no indicator (B-381 parity: the row keeps its
/// trailing time); see `LeoTaskIndicator.shownOnRow`.
final class TaskIndicatorView: UIView {
    static let size: CGFloat = 20
    private static let ringWidth: CGFloat = 1.5
    private static let wedgeInset: CGFloat = 3.5
    private static let mutedAlpha: CGFloat = 0.45

    private let ring = CAShapeLayer()
    private let wedge = CAShapeLayer()
    private let glyph = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private var indicator: LeoTaskIndicator?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isAccessibilityElement = false
        glyph.tintColor = .systemRed
        glyph.contentMode = .scaleAspectFit
        glyph.frame = bounds
        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        wedge.strokeColor = nil
        addSubview(glyph)
        for layer in [ring, wedge] { self.layer.addSublayer(layer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.size, height: Self.size) }

    /// Idempotent: the Agents list reapplies every second.
    func apply(_ indicator: LeoTaskIndicator) {
        guard indicator != self.indicator else { return }
        self.indicator = indicator
        render(indicator)
    }

    private func render(_ indicator: LeoTaskIndicator) {
        let fraction: Double?
        var isMuted = false
        switch indicator {
        case .progress(let value):
            fraction = value
        case .stalled(let value):
            fraction = value ?? 0
            isMuted = true
        case .failed:
            fraction = nil
        }
        let isGlyph: Bool = if case .failed = indicator { true } else { false }
        glyph.isHidden = !isGlyph
        ring.isHidden = isGlyph
        wedge.isHidden = ring.isHidden
        layer.opacity = 1
        if let fraction, !ring.isHidden {
            ringAndWedge(fraction: fraction, isMuted: isMuted)
        }
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
        if let indicator { render(indicator) }
    }
}

extension LeoTaskIndicator {
    /// What an iOS row draws: an indeterminate task shows nothing (no
    /// spinner, matching the Mac row from B-381); everything else as is.
    var shownOnRow: LeoTaskIndicator? {
        if case .progress(nil) = self { return nil }
        return self
    }
}
