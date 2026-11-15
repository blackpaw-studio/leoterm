import LeoKit
import UIKit

/// A chat message's text: selectable, with inline Markdown and tappable
/// links (opened in the default browser), sized to fit its text like a label.
final class ChatBodyTextView: UITextView {
    private static let codeBackground = UIColor.white.withAlphaComponent(0.22)

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `text` in `font` and `color`. In your own (accent-filled) bubbles
    /// links are white and underlined, so they read against the fill.
    func show(_ text: String, font: UIFont, color: UIColor, alignment: NSTextAlignment, isMine: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        linkTextAttributes = isMine
            ? [.foregroundColor: UIColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.foregroundColor: UIColor.tintColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        attributedText = Self.styled(
            LeoChatText.attributed(text),
            base: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph],
            codeBackground: isMine ? Self.codeBackground : nil)
    }

    /// Markdown runs as UIKit attributes: bold, italic and code become font
    /// traits, links stay `.link`.
    static func styled(
        _ source: AttributedString, base: [NSAttributedString.Key: Any], codeBackground: UIColor?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in source.runs {
            var attributes = base
            if let font = base[.font] as? UIFont {
                attributes[.font] = font.applying(run.inlinePresentationIntent ?? [])
            }
            if let url = run.link { attributes[.link] = url }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.inlinePresentationIntent?.contains(.code) == true, let codeBackground {
                attributes[.backgroundColor] = codeBackground
            }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private extension UIFont {
    func applying(_ intent: InlinePresentationIntent) -> UIFont {
        let isBold = intent.contains(.stronglyEmphasized)
        var font = self
        if intent.contains(.code) {
            font = .monospacedSystemFont(ofSize: pointSize, weight: isBold ? .bold : .regular)
        } else if isBold {
            font = font.with(.traitBold)
        }
        return intent.contains(.emphasized) ? font.with(.traitItalic) : font
    }

    private func with(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
