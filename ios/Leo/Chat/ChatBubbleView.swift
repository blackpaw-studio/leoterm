import LeoKit
import UIKit

/// The backdrop of a chat cell: an iMessage-style bubble (rounded corners,
/// and a tail on the sender's side for the last of a group), a rounded card,
/// or nothing. The bubble outline is LeoKit's, so Mac draws the same shape.
/// The layer is not masked, so a tail draws into the cell's side margin.
final class ChatBubbleView: UIView {
    enum Style: Equatable {
        case bubble(LeoChatBubbleGeometry.Side, LeoChatTranscript.GroupPosition)
        case card(radius: CGFloat)
        case plain
    }

    override class var layerClass: AnyClass { CAShapeLayer.self }

    var style = Style.plain { didSet { setNeedsLayout() } }
    /// Resolved against the current traits on each layout, since layer
    /// colours don't follow dark mode by themselves.
    var fillColor = UIColor.clear { didSet { setNeedsLayout() } }
    /// Fill with the view's own tint (the app's accent) instead of `fillColor`.
    var fillsWithTint = false { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.setNeedsLayout() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shape = layer as? CAShapeLayer else { return }
        shape.fillColor = (fillsWithTint ? tintColor : fillColor).resolvedColor(with: traitCollection).cgColor
        shape.path = path(in: bounds)
    }

    private func path(in rect: CGRect) -> CGPath? {
        switch style {
        case .plain:
            return nil
        case .card(let radius):
            return UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        case .bubble(let side, let position):
            let path = CGMutablePath()
            for element in LeoChatBubbleGeometry.outline(in: rect, side: side, position: position) {
                switch element {
                case .move(let point): path.move(to: point)
                case .line(let point): path.addLine(to: point)
                case .curve(let to, let c1, let c2): path.addCurve(to: to, control1: c1, control2: c2)
                case .corner(let t1, let t2, let radius): path.addArc(tangent1End: t1, tangent2End: t2, radius: radius)
                case .close: path.closeSubpath()
                }
            }
            return path
        }
    }
}
