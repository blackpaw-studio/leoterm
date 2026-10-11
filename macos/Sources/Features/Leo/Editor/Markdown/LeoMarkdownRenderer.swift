import AppKit

/// Renders Markdown natively for the pane's Rendered presentation (B-278):
/// Foundation's parser (`AttributedString(markdown:)`, full syntax with
/// GitHub tables), laid out with TextKit 1 blocks -- `NSTextTable` for
/// tables, `NSTextBlock` for code and quotes, `NSTextList` for lists. Pure
/// and side-effect free: images show their alt text and are never fetched,
/// and only web and mail links survive. Never throws: input the parser
/// can't take shows as plain text.
struct LeoMarkdownRenderer {
    /// Link schemes kept; any other link shows as plain text.
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    var baseSize = NSFont.systemFontSize + 1

    func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        }
        var builder = Builder(renderer: self)
        for run in parsed.runs {
            builder.append(String(parsed[run.range].characters), block: run.presentationIntent, inline: run.inlinePresentationIntent, link: run.link, isImage: run.imageURL != nil)
        }
        return builder.finish()
    }

    var bodyFont: NSFont { .systemFont(ofSize: baseSize) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }

    func headingFont(level: Int) -> NSFont {
        let scale: [CGFloat] = [2.0, 1.6, 1.3, 1.15, 1.0, 0.9]
        return .systemFont(ofSize: (baseSize * scale[min(max(level, 1), scale.count) - 1]).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        url.scheme.map { linkSchemes.contains($0.lowercased()) } ?? false
    }
}

extension LeoMarkdownRenderer {
    /// Collects runs into paragraphs: each block (one `PresentationIntent`)
    /// becomes one or more paragraphs ending in "\n", with block-level
    /// styling from its intent's components (innermost first).
    fileprivate struct Builder {
        let renderer: LeoMarkdownRenderer
        private let output = NSMutableAttributedString()
        private var current: PresentationIntent?
        private var paragraph = NSMutableAttributedString()
        /// One block object per quote / code block / table, so the
        /// paragraphs inside draw as one box.
        private var blocks: [Int: NSTextBlock] = [:]
        private var tables: [Int: NSTextTable] = [:]
        /// Each table's rows by identity, header row first.
        private var tableRows: [Int: [Int: Int]] = [:]
        private var lists: [Int: NSTextList] = [:]
        private var markedItems: Set<Int> = []

        init(renderer: LeoMarkdownRenderer) {
            self.renderer = renderer
        }

        mutating func append(_ text: String, block: PresentationIntent?, inline: InlinePresentationIntent?, link: URL?, isImage: Bool) {
            if block != current {
                flush()
                current = block
            }
            paragraph.append(NSAttributedString(string: Self.text(text, inline: inline), attributes: inlineAttributes(block: block, inline: inline, link: link, isImage: isImage)))
        }

        mutating func finish() -> NSAttributedString {
            flush()
            // No trailing blank paragraph after the last block.
            if output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
            return output
        }

        private static func text(_ text: String, inline: InlinePresentationIntent?) -> String {
            guard let inline else { return text }
            if inline.contains(.lineBreak) { return "\u{2028}" }
            if inline.contains(.softBreak) { return " " }
            return text
        }

        // MARK: Inline

        private func inlineAttributes(block: PresentationIntent?, inline: InlinePresentationIntent?, link: URL?, isImage: Bool) -> [NSAttributedString.Key: Any] {
            let kinds = block?.components.map(\.kind) ?? []
            var font = baseFont(for: kinds)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
            if let inline {
                if inline.contains(.code) {
                    font = renderer.codeFont
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if isImage {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                if let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) { font = italic }
            } else if let link, LeoMarkdownRenderer.isAllowedLink(link) {
                attributes[.link] = link
            }
            if kinds.contains(where: Self.isQuote) { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            attributes[.font] = font
            return attributes
        }

        private func baseFont(for kinds: [PresentationIntent.Kind]) -> NSFont {
            for kind in kinds {
                switch kind {
                case .header(let level): return renderer.headingFont(level: level)
                case .codeBlock: return renderer.codeFont
                case .tableHeaderRow: return .systemFont(ofSize: renderer.baseSize, weight: .semibold)
                default: continue
                }
            }
            return renderer.bodyFont
        }

        private static func isQuote(_ kind: PresentationIntent.Kind) -> Bool {
            if case .blockQuote = kind { return true }
            return false
        }

        // MARK: Blocks

        /// Ends the current block: styles its paragraph(s) and adds them.
        private mutating func flush() {
            defer { paragraph = NSMutableAttributedString() }
            guard paragraph.length > 0 || current != nil else { return }
            let components = current?.components ?? []
            // A code block's text carries its own line breaks.
            while paragraph.string.hasSuffix("\n") { paragraph.deleteCharacters(in: NSRange(location: paragraph.length - 1, length: 1)) }
            if components.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) {
                paragraph.setAttributedString(NSAttributedString(string: "\u{00A0}", attributes: [.font: renderer.bodyFont]))
            }
            let style = paragraphStyle(for: components)
            if let marker = listMarker(for: components) {
                paragraph.insert(NSAttributedString(string: marker, attributes: [.font: renderer.bodyFont, .foregroundColor: NSColor.secondaryLabelColor]), at: 0)
            }
            paragraph.append(NSAttributedString(string: "\n", attributes: [.font: renderer.bodyFont]))
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            output.append(paragraph)
        }

        private mutating func paragraphStyle(for components: [PresentationIntent.IntentType]) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = renderer.baseSize * 0.6
            var textBlocks: [NSTextBlock] = []
            var textLists: [NSTextList] = []
            var indent: CGFloat = 0
            // Outermost first, as TextKit nests blocks.
            for component in components.reversed() {
                switch component.kind {
                case .blockQuote:
                    textBlocks.append(block(component.identity, make: Self.quoteBlock))
                case .codeBlock:
                    textBlocks.append(block(component.identity, make: Self.codeBlock))
                    style.paragraphSpacing = 0
                case .orderedList, .unorderedList:
                    textLists.append(list(component))
                    indent += renderer.baseSize * 1.6
                case .table:
                    _ = table(component)
                case .tableCell(let column):
                    if let cell = tableCell(column: column, in: components) { textBlocks.append(cell) }
                    style.paragraphSpacing = 0
                case .header:
                    style.paragraphSpacingBefore = renderer.baseSize * 0.4
                case .thematicBreak:
                    textBlocks.append(Self.ruleBlock())
                default:
                    break
                }
            }
            style.textBlocks = textBlocks
            style.textLists = textLists
            if indent > 0 {
                style.headIndent = indent
                style.firstLineHeadIndent = indent - renderer.baseSize * 1.6
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.defaultTabInterval = indent
                style.paragraphSpacing = renderer.baseSize * 0.2
            }
            return style
        }

        /// "1.\t" or "•\t" on a list item's first paragraph; later
        /// paragraphs of the item are only indented.
        private mutating func listMarker(for components: [PresentationIntent.IntentType]) -> String? {
            guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
                  case .listItem(let ordinal) = components[itemIndex].kind,
                  !markedItems.contains(components[itemIndex].identity) else {
                return components.contains(where: { if case .listItem = $0.kind { true } else { false } }) ? "\t" : nil
            }
            markedItems.insert(components[itemIndex].identity)
            let depth = components.filter { if case .unorderedList = $0.kind { true } else if case .orderedList = $0.kind { true } else { false } }.count
            guard itemIndex + 1 < components.count else { return nil }
            if case .orderedList = components[itemIndex + 1].kind { return "\(ordinal).\t" }
            return ["•", "◦", "▪"][min(depth, 3) - 1] + "\t"
        }

        private mutating func block(_ identity: Int, make: () -> NSTextBlock) -> NSTextBlock {
            if let block = blocks[identity] { return block }
            let block = make()
            blocks[identity] = block
            return block
        }

        private mutating func list(_ component: PresentationIntent.IntentType) -> NSTextList {
            if let list = lists[component.identity] { return list }
            let format: NSTextList.MarkerFormat = if case .orderedList = component.kind { .decimal } else { .disc }
            let list = NSTextList(markerFormat: format, options: 0)
            lists[component.identity] = list
            return list
        }

        private mutating func table(_ component: PresentationIntent.IntentType) -> NSTextTable {
            if let table = tables[component.identity] { return table }
            let table = NSTextTable()
            if case .table(let columns) = component.kind { table.numberOfColumns = max(columns.count, 1) }
            table.collapsesBorders = true
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.setContentWidth(100, type: .percentageValueType)
            tables[component.identity] = table
            return table
        }

        /// The cell's block, placed by its row (header row first) and column.
        private mutating func tableCell(column: Int, in components: [PresentationIntent.IntentType]) -> NSTextTableBlock? {
            guard let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }),
                  let rowComponent = components.first(where: {
                      switch $0.kind {
                      case .tableHeaderRow, .tableRow: true
                      default: false
                      }
                  }) else { return nil }
            let table = table(tableComponent)
            var rows = tableRows[tableComponent.identity, default: [:]]
            let row = rows[rowComponent.identity] ?? rows.count
            rows[rowComponent.identity] = row
            tableRows[tableComponent.identity] = rows
            let isHeader = if case .tableHeaderRow = rowComponent.kind { true } else { false }
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
            cell.setBorderColor(.separatorColor)
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            if isHeader { cell.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            return cell
        }

        private static func codeBlock() -> NSTextBlock {
            let block = NSTextBlock()
            block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            block.setContentWidth(100, type: .percentageValueType)
            return block
        }

        private static func quoteBlock() -> NSTextBlock {
            let block = NSTextBlock()
            // Without a content width the block shrinks to its widest
            // glyph and a quote breaks after every character.
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.tertiaryLabelColor, for: .minX)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            return block
        }

        private static func ruleBlock() -> NSTextBlock {
            let block = NSTextBlock()
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(.separatorColor, for: .maxY)
            block.setContentWidth(100, type: .percentageValueType)
            return block
        }
    }
}
