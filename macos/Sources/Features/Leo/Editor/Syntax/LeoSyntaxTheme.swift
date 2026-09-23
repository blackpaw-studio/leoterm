import AppKit

/// The editor's font and token colours: the monospaced system font and
/// system semantic colours, so light and dark mode (and Increase Contrast)
/// both work without a palette of our own.
struct LeoSyntaxTheme {
    let font: NSFont
    let boldFont: NSFont
    let plainColor: NSColor

    static func system(fontSize: CGFloat = NSFont.systemFontSize) -> LeoSyntaxTheme {
        LeoSyntaxTheme(
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            boldFont: .monospacedSystemFont(ofSize: fontSize, weight: .bold),
            plainColor: .textColor
        )
    }

    func color(for token: LeoSyntaxToken) -> NSColor {
        switch token {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        case .literal: .systemPurple
        case .attribute: .systemOrange
        case .variable: .systemIndigo
        case .key: .systemBlue
        case .heading: .systemPink
        case .code: .systemBrown
        case .emphasis: .systemPurple
        case .link: .linkColor
        }
    }

    func isBold(_ token: LeoSyntaxToken) -> Bool {
        token == .heading
    }
}
