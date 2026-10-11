import Foundation
import LeoFeatures
import UIKit

/// Markdown to an attributed string for a UITextView, block by block
/// (`MarkdownBlocks`) so the block holding an agent's `line` can be found
/// and highlighted. Prose parses with `AttributedString(markdown:)`; its
/// presentation intents map to UIKit fonts and paragraph styles. Fenced
/// code renders as monospaced lines, so a line inside it highlights alone.
enum MarkdownRenderer {
    static func render(_ source: String, highlightLine: Int?) -> (text: NSAttributedString, highlight: NSRange?) {
        let document = MarkdownBlocks(source)
        let target = highlightLine.flatMap(document.blockIndex(containing:))
        let result = NSMutableAttributedString()
        var highlight: NSRange?
        for (index, block) in document.blocks.enumerated() {
            // The newline ends the previous block's last paragraph, whose own
            // paragraph spacing makes the gap.
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: Style.body])) }
            let start = result.length
            switch block.kind {
            case .code:
                let (code, lineRange) = renderCode(block, highlightLine: index == target ? highlightLine : nil)
                result.append(code)
                if let lineRange { highlight = NSRange(location: start + lineRange.location, length: lineRange.length) }
            case .prose:
                result.append(renderProse(block.text))
            }
            if index == target, highlight == nil { highlight = NSRange(location: start, length: result.length - start) }
        }
        return (result, highlight)
    }

    // MARK: Code

    private static func renderCode(_ block: MarkdownBlocks.Block, highlightLine: Int?) -> (NSAttributedString, NSRange?) {
        let result = NSMutableAttributedString()
        var highlight: NSRange?
        let lines = block.text.components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            let start = result.length
            let isLast = offset == lines.count - 1
            result.append(NSAttributedString(string: (line.isEmpty ? " " : line) + (isLast ? "" : "\n"), attributes: [
                .font: Style.code, .foregroundColor: UIColor.label, .backgroundColor: UIColor.secondarySystemFill,
                .paragraphStyle: isLast ? Style.lastCodeLine : Style.codeBlock,
            ]))
            if let highlightLine, highlightLine == block.firstContentLine + offset {
                highlight = NSRange(location: start, length: result.length - start)
            }
        }
        return (result, highlight)
    }

    // MARK: Prose

    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static func renderProse(_ text: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: Style.body, .foregroundColor: UIColor.label])
        }
        let result = NSMutableAttributedString()
        var previous: [PresentationIntent.IntentType]?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            // A new paragraph (or table cell) starts when the innermost
            // block changes: cells of one row are tab-separated.
            if components.first?.identity != previous?.first?.identity {
                if let last = previous {
                    let sameRow = rowIdentity(components) != nil && rowIdentity(components) == rowIdentity(last)
                    result.append(NSAttributedString(string: sameRow ? "\t" : "\n", attributes: [.font: Style.body, .paragraphStyle: paragraphStyle(components)]))
                    if sameRow {
                        previous = components
                        result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes(for: run, components: components)))
                        continue
                    }
                }
                if let prefix = listPrefix(components) {
                    result.append(NSAttributedString(string: prefix, attributes: [.font: Style.body, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraphStyle(components)]))
                }
            }
            previous = components
            if components.contains(where: { $0.kind == .thematicBreak }) {
                result.append(NSAttributedString(string: "───", attributes: [.font: Style.body, .foregroundColor: UIColor.separator]))
                continue
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes(for: run, components: components)))
        }
        return result
    }

    private static func rowIdentity(_ components: [PresentationIntent.IntentType]) -> Int? {
        components.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }?.identity
    }

    private static func listPrefix(_ components: [PresentationIntent.IntentType]) -> String? {
        guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case .listItem(let ordinal) = components[itemIndex].kind else { return nil }
        let depth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
        let isOrdered = components[(itemIndex + 1)...].first { $0.kind == .orderedList || $0.kind == .unorderedList }?.kind == .orderedList
        let marker = isOrdered ? "\(ordinal)." : (depth > 1 ? "◦" : "•")
        return marker + "\t"
    }

    private static func attributes(for run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType]) -> [NSAttributedString.Key: Any] {
        var font = Style.body
        var color = UIColor.label
        for component in components {
            switch component.kind {
            case .header(let level): font = Style.heading(level)
            case .codeBlock: font = Style.code
            case .blockQuote: color = .secondaryLabel
            case .tableHeaderRow: font = font.withWeight(.semibold)
            default: break
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraphStyle(components)]
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = Style.inlineCode(matching: font)
                attributes[.backgroundColor] = UIColor.tertiarySystemFill
            }
            var traits = font.fontDescriptor.symbolicTraits
            if inline.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if inline.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: 0) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        // Agent-written: only web links are live.
        if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased()) {
            attributes[.link] = link
        }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        return attributes
    }

    private static func paragraphStyle(_ components: [PresentationIntent.IntentType]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
        let quotes = components.filter { $0.kind == .blockQuote }.count
        let indent = CGFloat(lists) * 22 + CGFloat(quotes) * 14
        if lists > 0 {
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.firstLineHeadIndent = indent - 18
            style.headIndent = indent
        } else {
            style.firstLineHeadIndent = indent
            style.headIndent = indent
        }
        if components.contains(where: { if case .header = $0.kind { true } else { false } }) {
            style.paragraphSpacingBefore = 10
        }
        if components.contains(where: { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }) {
            style.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 110) }
        }
        return style
    }

    private enum Style {
        static var body: UIFont { .preferredFont(forTextStyle: .body) }
        static var code: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular)) }

        static func inlineCode(matching font: UIFont) -> UIFont {
            .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
        }

        static func heading(_ level: Int) -> UIFont {
            let style: UIFont.TextStyle = switch level {
            case 1: .title1
            case 2: .title2
            case 3: .title3
            default: .headline
            }
            return UIFont.preferredFont(forTextStyle: style).withWeight(.bold)
        }

        /// The block gap after code (a paragraph's spacing follows it).
        static var lastCodeLine: NSParagraphStyle {
            let style = codeBlock.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = 12
            return style
        }

        static var codeBlock: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            style.lineBreakMode = .byCharWrapping
            return style
        }
    }
}
