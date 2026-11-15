import UIKit

/// The Agents list row's emoji tile: the emoji on a neutral rounded square
/// with the status dot on its bottom-right corner. Drawn into one image (for
/// `UIListContentConfiguration.image`) with a light and a dark variant, so it
/// follows the appearance without the row redrawing it.
enum AgentRowTile {
    static let size = CGSize(width: 44, height: 44)
    private static let tile = CGRect(x: 0, y: 2, width: 38, height: 38)
    private static let cornerRadius: CGFloat = 10
    private static let emojiSize: CGFloat = 22
    private static let dotDiameter: CGFloat = 12
    private static let ringWidth: CGFloat = 2.5

    static func image(emoji: String, statusTint: UIColor) -> UIImage {
        let light = render(emoji: emoji, statusTint: statusTint, style: .light)
        let dark = render(emoji: emoji, statusTint: statusTint, style: .dark)
        // The scale is part of the match: without it the dark variant reads as 1x and draws oversized.
        let darkTraits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: dark.scale)])
        light.imageAsset?.register(dark, with: darkTraits)
        return light
    }

    private static func render(emoji: String, statusTint: UIColor, style: UIUserInterfaceStyle) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            traits.performAsCurrent {
                UIColor.tertiarySystemFill.setFill()
                UIBezierPath(roundedRect: tile, cornerRadius: cornerRadius).fill()
                let font = UIFont.systemFont(ofSize: emojiSize)
                let text = NSAttributedString(string: emoji, attributes: [.font: font])
                let bounds = text.size()
                text.draw(at: CGPoint(x: tile.midX - bounds.width / 2, y: tile.midY - bounds.height / 2))

                let dot = CGRect(
                    x: tile.maxX - dotDiameter / 2 - 3, y: tile.maxY - dotDiameter / 2 - 3, width: dotDiameter, height: dotDiameter
                )
                UIColor.secondarySystemGroupedBackground.setFill()
                UIBezierPath(ovalIn: dot.insetBy(dx: -ringWidth, dy: -ringWidth)).fill()
                statusTint.setFill()
                UIBezierPath(ovalIn: dot).fill()
            }
        }
    }
}

/// The 4pt bar on a row's leading edge, drawn as the cell background's
/// custom view so the selection and highlight states keep working.
final class AgentRowBar: UIView {
    static let width: CGFloat = 4

    init(color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = color
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A background container that pins the bar to the leading edge, full height.
final class AgentRowBackground: UIView {
    init(barColor: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let bar = AgentRowBar(color: barColor)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: AgentRowBar.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
