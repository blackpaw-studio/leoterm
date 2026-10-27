import LeoFeatures
import LeoKit
import UIKit

/// The line of CPU / memory / disk meters under a machine's name, drawn in
/// one of the Stats styles. Metrics follow the approved iOS mockup.
final class MeterLineView: UIView {
    private let content = UIStackView()
    private var drawn: (meters: [MachineMeter], style: LeoStatsStyle)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(meters: [MachineMeter], style: LeoStatsStyle) {
        // Rebuilding redraws every gauge from scratch; an unchanged line stays put.
        guard drawn?.meters != meters || drawn?.style != style else { return }
        drawn = (meters, style)
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.axis = .horizontal
        content.alignment = .center
        content.distribution = .fill
        content.spacing = 0
        switch style {
        case .capsules:
            content.alignment = .center
            content.spacing = 24
            meters.forEach { content.addArrangedSubview(CapsuleMeterView(meter: $0)) }
            content.addArrangedSubview(UIView())
        case .bars:
            content.alignment = .top
            content.distribution = .fillEqually
            content.spacing = 16
            meters.forEach { content.addArrangedSubview(BarMeterView(meter: $0)) }
        case .rings:
            content.distribution = .fillEqually
            content.spacing = 16
            meters.forEach { content.addArrangedSubview(RingMeterView(meter: $0)) }
        case .numbers:
            let label = UILabel()
            label.attributedText = Self.numbers(meters)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            content.addArrangedSubview(label)
        case .off:
            break
        }
        accessibilityLabel = meters.map { "\(MeterAppearance.name($0.kind)) \($0.percentText)" }.joined(separator: ", ")
    }

    private static func numbers(_ meters: [MachineMeter]) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let semibold = font.withWeight(.semibold)
        let result = NSMutableAttributedString()
        for (index, meter) in meters.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]))
            }
            result.append(NSAttributedString(string: MeterAppearance.key(meter.kind) + " ", attributes: [.font: semibold, .foregroundColor: UIColor.tertiaryLabel]))
            let alarming = meter.level != .normal
            result.append(NSAttributedString(string: meter.percentText, attributes: [
                .font: alarming ? semibold : font,
                .foregroundColor: alarming ? MeterAppearance.color(meter.level) : UIColor.secondaryLabel,
            ]))
        }
        return result
    }
}

/// An outlined capsule filled from the bottom, with its key stacked
/// vertically beside it.
private final class CapsuleMeterView: UIView {
    private static let size = CGSize(width: 15, height: 30)

    init(meter: MachineMeter) {
        super.init(frame: .zero)
        let key = UILabel()
        key.numberOfLines = 3
        key.textAlignment = .center
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.minimumLineHeight = 9.3
        style.maximumLineHeight = 9.3
        key.attributedText = NSAttributedString(
            string: MeterAppearance.key(meter.kind).map(String.init).joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: MeterAppearance.capsuleLabel, .paragraphStyle: style]
        )
        let capsule = CapsuleShape(fraction: meter.fraction, color: MeterAppearance.color(meter.level))
        let row = UIStackView(arrangedSubviews: [key, capsule])
        row.spacing = 3.75
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            key.widthAnchor.constraint(equalToConstant: 9.75),
            capsule.widthAnchor.constraint(equalToConstant: Self.size.width),
            capsule.heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class CapsuleShape: UIView {
    private let fill = UIView()
    private let fraction: Double?

    init(fraction: Double?, color: UIColor) {
        self.fraction = fraction
        super.init(frame: .zero)
        layer.borderWidth = 1.5
        layer.cornerRadius = 7.5
        layer.cornerCurve = .continuous
        fill.backgroundColor = color
        fill.layer.cornerRadius = 4.5
        fill.layer.cornerCurve = .continuous
        fill.isHidden = fraction == nil
        addSubview(fill)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CapsuleShape, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 1.5
        let inner = bounds.insetBy(dx: inset, dy: inset)
        let height = max(4.5, inner.height * (fraction ?? 0))
        fill.frame = CGRect(x: inner.minX, y: inner.maxY - height, width: inner.width, height: height)
    }

    private func updateColors() {
        layer.borderColor = MeterAppearance.capsuleBorder.resolvedColor(with: traitCollection).cgColor
        backgroundColor = MeterAppearance.capsuleFill
    }
}

/// A key and value above a thin horizontal bar.
private final class BarMeterView: UIView {
    init(meter: MachineMeter) {
        super.init(frame: .zero)
        let key = UILabel()
        key.attributedText = NSAttributedString(string: MeterAppearance.key(meter.kind), attributes: [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.tertiaryLabel, .kern: 0.55,
        ])
        let value = UILabel()
        let alarming = meter.level != .normal
        value.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: alarming ? .semibold : .regular)
        value.textColor = alarming ? MeterAppearance.color(meter.level) : .secondaryLabel
        value.text = meter.percentText
        key.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [key, UIView(), value])
        header.alignment = .firstBaseline
        let bar = BarShape(fraction: meter.fraction, color: MeterAppearance.color(meter.level))
        let column = UIStackView(arrangedSubviews: [header, bar])
        column.axis = .vertical
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class BarShape: UIView {
    private let fill = UIView()
    private let fraction: Double?

    init(fraction: Double?, color: UIColor) {
        self.fraction = fraction
        super.init(frame: .zero)
        backgroundColor = MeterAppearance.track
        layer.cornerRadius = 2
        clipsToBounds = true
        fill.backgroundColor = color
        fill.layer.cornerRadius = 2
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * (fraction ?? 0), height: bounds.height)
    }
}

/// A circular gauge with its value inside and its key beside it.
private final class RingMeterView: UIView {
    init(meter: MachineMeter) {
        super.init(frame: .zero)
        let ring = RingShape(meter: meter)
        let key = UILabel()
        key.attributedText = NSAttributedString(string: MeterAppearance.key(meter.kind), attributes: [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.tertiaryLabel, .kern: 0.55,
        ])
        let row = UIStackView(arrangedSubviews: [ring, key, UIView()])
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RingShape: UIView {
    private static let diameter: CGFloat = 36
    private static let lineWidth: CGFloat = 3.6
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let fraction: Double?
    private let arcColor: UIColor

    init(meter: MachineMeter) {
        fraction = meter.fraction
        arcColor = MeterAppearance.color(meter.level)
        super.init(frame: .zero)
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            self.layer.addSublayer(layer)
        }
        arc.lineCap = .round
        arc.strokeEnd = CGFloat(fraction ?? 0)
        arc.isHidden = fraction == nil
        let value = UILabel()
        value.font = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        value.text = meter.percentText
        value.textAlignment = .center
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.7
        value.translatesAutoresizingMaskIntoConstraints = false
        addSubview(value)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            value.centerXAnchor.constraint(equalTo: centerXAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.widthAnchor.constraint(lessThanOrEqualToConstant: Self.diameter - 2 * Self.lineWidth),
        ])
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RingShape, _) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.lineWidth / 2
        // Start at 12 o'clock, clockwise.
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - inset,
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        )
        track.path = path.cgPath
        arc.path = path.cgPath
    }

    private func updateColors() {
        track.strokeColor = MeterAppearance.track.resolvedColor(with: traitCollection).cgColor
        arc.strokeColor = arcColor.resolvedColor(with: traitCollection).cgColor
    }
}
