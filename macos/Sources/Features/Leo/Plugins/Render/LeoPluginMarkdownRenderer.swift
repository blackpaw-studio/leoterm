import AppKit
import LeoKit

/// Turns the restricted-Markdown AST into native attributed text. All colours
/// are dynamic system colours, so light and dark mode need no work here.
enum LeoPluginMarkdownRenderer {
    static let bodySize: CGFloat = NSFont.systemFontSize
    private static let paragraphSpacing: CGFloat = 8
    private static let listIndent: CGFloat = 18

    static func attributedString(for blocks: [LeoPluginMarkdown.Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in blocks {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(render(block))
        }
        return out
    }

    // MARK: Blocks

    private static func render(_ block: LeoPluginMarkdown.Block) -> NSAttributedString {
        switch block {
        case .heading(let level, let content):
            let size = headingSize(level)
            return paragraph(inlines(content, base: Style(size: size, bold: true)), style: blockStyle(spacingBefore: 4))
        case .paragraph(let content):
            return paragraph(inlines(content, base: Style()), style: blockStyle())
        case .list(let ordered, let items):
            return list(ordered: ordered, items: items)
        case .codeBlock(let code):
            return paragraph(
                NSAttributedString(string: code, attributes: codeAttributes(size: bodySize - 1)),
                style: blockStyle(firstIndent: 8, indent: 8))
        }
    }

    private static func list(ordered: Bool, items: [[LeoPluginMarkdown.Inline]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let marker = ordered ? "\(index + 1)." : "•"
            let line = NSMutableAttributedString(string: "\(marker)\t", attributes: Style().attributes)
            line.append(inlines(item, base: Style()))
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 0
            style.headIndent = listIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
            style.defaultTabInterval = listIndent
            style.paragraphSpacing = index == items.count - 1 ? paragraphSpacing : 2
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private static func paragraph(_ text: NSAttributedString, style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func blockStyle(spacingBefore: CGFloat = 0, firstIndent: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = firstIndent
        style.headIndent = indent
        return style
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: bodySize * 1.7
        case 2: bodySize * 1.4
        case 3: bodySize * 1.2
        default: bodySize * 1.05
        }
    }

    // MARK: Inlines

    private struct Style {
        var size: CGFloat = LeoPluginMarkdownRenderer.bodySize
        var bold = false
        var italic = false
        var code = false
        var link: URL?

        var attributes: [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            if code {
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            if let link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
            }
            return attrs
        }

        private var font: NSFont {
            if code { return .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let base = NSFont.systemFont(ofSize: size)
            guard !traits.isEmpty else { return base }
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
    }

    private static func inlines(_ content: [LeoPluginMarkdown.Inline], base: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in content {
            switch inline {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: base.attributes))
            case .emphasis(let inner):
                var style = base; style.italic = true
                out.append(inlines(inner, base: style))
            case .strong(let inner):
                var style = base; style.bold = true
                out.append(inlines(inner, base: style))
            case .code(let code):
                var style = base; style.code = true
                out.append(NSAttributedString(string: code, attributes: style.attributes))
            case .link(let text, let url):
                var style = base
                // The AST already insists on https; check again at the point of use.
                if let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil {
                    style.link = parsed
                }
                out.append(inlines(text, base: style))
            }
        }
        return out
    }

    private static func codeAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        var style = Style(size: size + 1)
        style.code = true
        return style.attributes
    }
}
