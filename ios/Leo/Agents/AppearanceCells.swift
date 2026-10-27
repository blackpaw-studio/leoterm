import LeoKit
import UIKit

/// One palette color in the Appearance sheet: a filled circle, ringed and
/// checked while it is this agent's own pick.
final class SwatchCell: UICollectionViewCell {
    private let circle = UIView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(weight: .bold)))
    private static let diameter: CGFloat = 34

    override init(frame: CGRect) {
        super.init(frame: frame)
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.layer.cornerRadius = Self.diameter / 2
        circle.layer.borderWidth = 0
        check.tintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(circle)
        circle.addSubview(check)
        NSLayoutConstraint.activate([
            circle.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: Self.diameter),
            circle.heightAnchor.constraint(equalToConstant: Self.diameter),
            check.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: LeoAppearanceColor, isPicked: Bool) {
        circle.backgroundColor = color.uiColor
        check.isHidden = !isPicked
        accessibilityLabel = color.displayName
        accessibilityTraits = isPicked ? [.button, .selected] : .button
    }
}

/// One emoji in the grid, with a rounded highlight while it is the agent's.
final class EmojiCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 30)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(entry: LeoEmojiEntry, isPicked: Bool) {
        label.text = entry.emoji
        contentView.backgroundColor = isPicked ? .tintColor.withAlphaComponent(0.2) : .clear
        accessibilityLabel = entry.name
        accessibilityTraits = isPicked ? [.button, .selected] : .button
    }
}
