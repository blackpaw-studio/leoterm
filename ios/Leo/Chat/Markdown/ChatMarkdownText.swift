import LeoKit
import UIKit

/// Turns parsed inline runs into attributed text. Fonts follow Dynamic Type;
/// colors are dynamic so light and dark switch without a refresh. The `.link`
/// attribute comes only from `run.link`, which the parser has already
/// filtered through the link allowlist.
enum ChatMarkdownText {
    enum Style: Equatable { case body, heading(Int), tableHeader, quote }

    private static let codeBaseSize: CGFloat = 15

    static func attributed(_ runs: [LeoMarkdownRun], style: Style, traits: UITraitCollection) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run, style: style, traits: traits)))
        }
        return result
    }

    // MARK: Fonts

    private static func baseFont(_ style: Style, traits: UITraitCollection) -> UIFont {
        switch style {
        case .body, .quote:
            return .preferredFont(forTextStyle: .body, compatibleWith: traits)
        case .tableHeader:
            return weighted(.body, .semibold, traits: traits)
        case .heading(let level):
            switch level {
            case 1: return weighted(.title1, .bold, traits: traits)
            case 2: return weighted(.title2, .bold, traits: traits)
            case 3: return weighted(.title3, .semibold, traits: traits)
            case 4: return weighted(.headline, .semibold, traits: traits)
            case 5: return weighted(.subheadline, .semibold, traits: traits)
            default: return weighted(.footnote, .semibold, traits: traits)
            }
        }
    }

    private static func weighted(_ textStyle: UIFont.TextStyle, _ weight: UIFont.Weight, traits: UITraitCollection) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).pointSize
        return .systemFont(ofSize: size, weight: weight)
    }

    static func monospacedFont(traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: codeBaseSize, weight: .regular),
            compatibleWith: traits
        )
    }

    private static func font(for run: LeoMarkdownRun, style: Style, traits: UITraitCollection) -> UIFont {
        let base = run.traits.contains(.code) ? monospacedFont(traits: traits) : baseFont(style, traits: traits)
        var symbolic = base.fontDescriptor.symbolicTraits
        if run.traits.contains(.strong) { symbolic.insert(.traitBold) }
        if run.traits.contains(.emphasis) || run.traits.contains(.image) { symbolic.insert(.traitItalic) }
        guard symbolic != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(symbolic) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    // MARK: Attributes

    private static func attributes(for run: LeoMarkdownRun, style: Style, traits: UITraitCollection) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run, style: style, traits: traits),
            .foregroundColor: foreground(for: run, style: style),
        ]
        if run.traits.contains(.code) { attributes[.backgroundColor] = UIColor.tertiarySystemFill }
        if run.traits.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attributes[.link] = link }
        return attributes
    }

    private static func foreground(for run: LeoMarkdownRun, style: Style) -> UIColor {
        if run.traits.contains(.image) { return .secondaryLabel }
        return style == .quote ? .secondaryLabel : .label
    }
}
