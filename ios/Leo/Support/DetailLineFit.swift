import UIKit

/// Fits a one-line detail so its tail survives: the title is cut with an
/// ellipsis and the suffix (" · no update for 21m") stays whole, instead of
/// the label's tail truncation eating the most useful part.
enum DetailLineFit {
    static func fit(text: String, suffix: String?, font: UIFont, width: CGFloat) -> String {
        guard let suffix, text.hasSuffix(suffix), measure(text, font) > width else { return text }
        var title = Array(text.dropLast(suffix.count))
        while !title.isEmpty {
            title.removeLast()
            let candidate = String(title).trimmingCharacters(in: .whitespaces) + "…" + suffix
            if measure(candidate, font) <= width { return candidate }
        }
        return "…" + suffix
    }

    private static func measure(_ text: String, _ font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
