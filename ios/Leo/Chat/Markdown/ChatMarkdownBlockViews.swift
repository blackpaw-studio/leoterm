import LeoKit
import UIKit

/// Builds UIKit views for the Markdown block model: one vertical stack per
/// container, one selectable non-scrolling text view per text block. Every
/// color is a dynamic `UIColor` (no layer `CGColor`), so appearance changes
/// need no rebuild.
enum ChatMarkdownBlockViews {
    static let blockSpacing: CGFloat = 12
    static let maxColumnWidth: CGFloat = 280
    /// Rendering budget: past either limit the document shows as raw text rather
    /// than building thousands of text views on the main actor.
    static let maxBlocks = 2_000
    static let maxTableCells = 2_000
    /// Block nesting (lists, quotes) rendered recursively; mirrors the parser's cap.
    static let maxNesting = 32
    private static let minColumnWidth: CGFloat = 44
    private static let cellInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    private static let bullets = ["•", "◦", "▪"]

    /// Where a block sits: list depth picks the bullet, quotes dim their text.
    private struct Context {
        let traits: UITraitCollection
        var depth = 0
        var nesting = 0
        var isQuoted = false
        var textStyle: ChatMarkdownText.Style { isQuoted ? .quote : .body }
    }

    @MainActor static func view(for block: LeoMarkdownBlock, traits: UITraitCollection) -> UIView {
        view(for: block, context: Context(traits: traits))
    }

    /// The rendered document, or, past the rendering budget, its raw text
    /// under a short note.
    @MainActor static func renderedView(for document: LeoMarkdownDocument, source: String, traits: UITraitCollection) -> UIView {
        guard document.blockCount > maxBlocks || document.tableCellCount > maxTableCells else {
            return stack(for: document.blocks, traits: traits)
        }
        return fallbackView(source: source, traits: traits)
    }

    @MainActor private static func fallbackView(source: String, traits: UITraitCollection) -> UIView {
        let note = UILabel()
        note.font = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.text = String(localized: "Too large to format — showing raw text")
        let raw = textView(NSAttributedString(string: source, attributes: [
            .font: ChatMarkdownText.monospacedFont(traits: traits),
            .foregroundColor: UIColor.label,
        ]))
        raw.accessibilityIdentifier = "markdown.fallback"
        let column = UIStackView(arrangedSubviews: [note, raw])
        column.axis = .vertical
        column.spacing = blockSpacing
        return column
    }

    @MainActor static func stack(for blocks: [LeoMarkdownBlock], traits: UITraitCollection) -> UIStackView {
        stack(blocks, context: Context(traits: traits))
    }

    // MARK: Dispatch

    @MainActor private static func stack(_ blocks: [LeoMarkdownBlock], context: Context, spacing: CGFloat = blockSpacing) -> UIStackView {
        let column = UIStackView(arrangedSubviews: blocks.map { view(for: $0, context: context) })
        column.axis = .vertical
        column.spacing = spacing
        return column
    }

    @MainActor private static func view(for block: LeoMarkdownBlock, context: Context) -> UIView {
        // The parser already caps nesting; this bounds the recursion for any other caller.
        if context.nesting > maxNesting { return UIView() }
        switch block {
        case .heading(let level, let runs):
            return textView(ChatMarkdownText.attributed(runs, style: .heading(level), traits: context.traits))
        case .paragraph(let runs):
            return textView(ChatMarkdownText.attributed(runs, style: context.textStyle, traits: context.traits))
        case .list(let list):
            return listView(list, context: context)
        case .code(_, let text):
            return codeView(text, traits: context.traits)
        case .quote(let blocks):
            return quoteView(blocks, context: context)
        case .rule:
            return ruleView(traits: context.traits)
        case .table(let table):
            return tableView(table, traits: context.traits)
        }
    }

    // MARK: Text

    @MainActor private static func textView(_ text: NSAttributedString, insets: UIEdgeInsets = .zero) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textContainerInset = insets
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = text
        return view
    }

    // MARK: Lists and quotes

    @MainActor private static func listView(_ list: LeoMarkdownList, context: Context) -> UIView {
        var inner = context
        inner.depth += 1
        inner.nesting += 1
        let rows = list.items.enumerated().map { index, item -> UIView in
            let marker = UILabel()
            marker.font = .preferredFont(forTextStyle: .body, compatibleWith: context.traits)
            marker.textColor = context.isQuoted ? .secondaryLabel : .label
            marker.text = list.isOrdered ? "\(list.start + index)." : bullets[context.depth % bullets.count]
            marker.textAlignment = .right
            marker.setContentHuggingPriority(.required, for: .horizontal)
            marker.setContentCompressionResistancePriority(.required, for: .horizontal)
            marker.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            let row = UIStackView(arrangedSubviews: [marker, stack(item, context: inner, spacing: 6)])
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 8
            return row
        }
        let column = UIStackView(arrangedSubviews: rows)
        column.axis = .vertical
        column.spacing = 6
        return column
    }

    @MainActor private static func quoteView(_ blocks: [LeoMarkdownBlock], context: Context) -> UIView {
        var inner = context
        inner.isQuoted = true
        inner.nesting += 1
        let bar = UIView()
        bar.backgroundColor = .tertiaryLabel
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let row = UIStackView(arrangedSubviews: [bar, stack(blocks, context: inner, spacing: 8)])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .fill
        return row
    }

    @MainActor private static func ruleView(traits: UITraitCollection) -> UIView {
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.heightAnchor.constraint(equalToConstant: hairline(traits)).isActive = true
        return rule
    }

    private static func hairline(_ traits: UITraitCollection) -> CGFloat {
        1 / max(traits.displayScale, 1)
    }

    // MARK: Code

    /// A horizontally scrolling, unwrapped monospaced block.
    @MainActor private static func codeView(_ code: String, traits: UITraitCollection) -> UIView {
        let text = NSAttributedString(string: code, attributes: [
            .font: ChatMarkdownText.monospacedFont(traits: traits),
            .foregroundColor: UIColor.label,
        ])
        let content = textView(text)
        content.textContainer.lineBreakMode = .byClipping
        content.textContainer.widthTracksTextView = false
        let width = naturalWidth(of: text)
        content.widthAnchor.constraint(equalToConstant: width).isActive = true

        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "markdown.code"
        scroll.backgroundColor = .secondarySystemBackground
        scroll.layer.cornerRadius = 8
        scroll.clipsToBounds = true
        scroll.alwaysBounceHorizontal = false
        pin(content, in: scroll, insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        return scroll
    }

    private static func naturalWidth(of text: NSAttributedString) -> CGFloat {
        let bounds = text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.width) + 1
    }

    /// Pins `content` to the scroll view's content guide and sizes the frame to its height.
    @MainActor private static func pin(_ content: UIView, in scroll: UIScrollView, insets: UIEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: guide.heightAnchor),
        ])
    }

    // MARK: Tables

    /// Cells wrap inside columns capped at `maxColumnWidth`; the grid scrolls
    /// horizontally when wider than the screen. Hairline gaps over a separator
    /// background draw the borders.
    @MainActor private static func tableView(_ table: LeoMarkdownTable, traits: UITraitCollection) -> UIView {
        let columns = table.alignments.count
        let styled = ([(table.header, true)] + table.rows.map { ($0, false) }).map { row, isHeader in
            row.map { ChatMarkdownText.attributed($0, style: isHeader ? .tableHeader : .body, traits: traits) }
        }
        let widths = (0..<columns).map { column in
            let widest = styled.map { naturalWidth(of: $0[column]) }.max() ?? 0
            return min(maxColumnWidth, max(minColumnWidth, widest + cellInsets.left + cellInsets.right))
        }
        let gap = hairline(traits)
        let rows = styled.enumerated().map { rowIndex, cells -> UIView in
            let views = cells.enumerated().map { column, text in
                cell(text, width: widths[column], alignment: table.alignments[column], isHeader: rowIndex == 0)
            }
            let row = UIStackView(arrangedSubviews: views)
            row.axis = .horizontal
            row.spacing = gap
            row.alignment = .fill
            return row
        }
        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.spacing = gap
        let frame = UIView()
        frame.backgroundColor = .separator
        grid.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: frame.topAnchor, constant: gap),
            grid.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -gap),
            grid.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: gap),
            grid.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -gap),
        ])
        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "markdown.table"
        scroll.alwaysBounceHorizontal = false
        pin(frame, in: scroll, insets: .zero)
        return scroll
    }

    @MainActor private static func cell(_ text: NSAttributedString, width: CGFloat, alignment: LeoMarkdownTable.Alignment, isHeader: Bool) -> UIView {
        let content = textView(text, insets: cellInsets)
        content.textAlignment = switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
        let container = UIView()
        container.backgroundColor = isHeader ? .secondarySystemBackground : .systemBackground
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }
}
