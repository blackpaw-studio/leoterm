import Foundation

/// Folds Foundation's flat, intent-tagged `AttributedString` runs into the
/// `LeoMarkdownBlock` tree. Each run carries its block ancestry as a path of
/// (kind, identity) pairs; runs sharing an identity belong to the same block.
enum LeoMarkdownParser {
    /// Deepest block nesting folded recursively. Deeper documents (a 10k-level
    /// `>` chain would overflow the stack) show as plain text instead.
    static let maxNestingDepth = 32

    private typealias Kind = PresentationIntent.Kind

    private final class Node {
        let kind: Kind?
        let identity: Int
        var children: [Node] = []
        /// Child lookup by block identity; `children` keeps first-seen order.
        var childByIdentity: [Int: Node] = [:]
        var runs: [LeoMarkdownRun] = []

        init(kind: Kind?, identity: Int) {
            self.kind = kind
            self.identity = identity
        }
    }

    static func blocks(from markdown: String) -> [LeoMarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [.paragraph([LeoMarkdownRun(text: markdown)])]
        }
        let depthLimit = maxNestingDepth
        let isTooDeep = parsed.runs.contains { ($0.presentationIntent?.components.count ?? 0) > depthLimit }
        if isTooDeep { return [.paragraph([LeoMarkdownRun(text: markdown)])] }
        let root = Node(kind: nil, identity: 0)
        var syntheticIdentity = 0
        for run in parsed.runs {
            let leaf = descend(root, path: run.presentationIntent?.components.reversed() ?? [], syntheticIdentity: &syntheticIdentity)
            leaf.runs.append(makeRun(text: String(parsed[run.range].characters), run: run))
        }
        return fold(children: root.children)
    }

    // MARK: Tree building

    private static func descend(_ root: Node, path: [PresentationIntent.IntentType], syntheticIdentity: inout Int) -> Node {
        var current = root
        var steps = path.map { (kind: Optional($0.kind), identity: $0.identity) }
        if steps.isEmpty {
            // Run with no block intent: group contiguous ones into one paragraph.
            if let last = current.children.last, last.identity < 0 { return last }
            syntheticIdentity -= 1
            steps = [(.paragraph, syntheticIdentity)]
        }
        for step in steps {
            if let existing = current.childByIdentity[step.identity] {
                current = existing
            } else {
                let node = Node(kind: step.kind, identity: step.identity)
                current.children.append(node)
                current.childByIdentity[step.identity] = node
                current = node
            }
        }
        return current
    }

    private static func makeRun(text: String, run: AttributedString.Runs.Run) -> LeoMarkdownRun {
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.lineBreak) { return LeoMarkdownRun(text: "\n") }
        if inline.contains(.softBreak) { return LeoMarkdownRun(text: " ") }
        var traits: LeoMarkdownRun.Traits = []
        if inline.contains(.emphasized) { traits.insert(.emphasis) }
        if inline.contains(.stronglyEmphasized) { traits.insert(.strong) }
        if inline.contains(.code) { traits.insert(.code) }
        if inline.contains(.strikethrough) { traits.insert(.strikethrough) }
        if run.imageURL != nil {
            return LeoMarkdownRun(text: text, traits: traits.union(.image))
        }
        let link = run.link.flatMap { LeoMarkdownLinkPolicy.allows($0) ? $0 : nil }
        return LeoMarkdownRun(text: text, traits: traits, link: link)
    }

    // MARK: Folding

    private static func fold(children: [Node]) -> [LeoMarkdownBlock] {
        children.compactMap(block(for:))
    }

    /// Child blocks plus any inline runs sitting directly in the container
    /// (loose text in a list item or quote) as a leading paragraph.
    private static func containerBlocks(_ node: Node) -> [LeoMarkdownBlock] {
        let direct: [LeoMarkdownBlock] = node.runs.isEmpty ? [] : [.paragraph(node.runs)]
        return direct + fold(children: node.children)
    }

    private static func block(for node: Node) -> LeoMarkdownBlock? {
        guard let kind = node.kind else { return nil }
        switch kind {
        case .paragraph:
            return .paragraph(node.runs)
        case .header(let level):
            return .heading(level: level, node.runs)
        case .codeBlock(let language):
            var text = node.runs.map(\.text).joined()
            while text.hasSuffix("\n") { text.removeLast() }
            let hint = language.flatMap { $0.isEmpty ? nil : $0 }
            return .code(language: hint, text: text)
        case .blockQuote:
            return .quote(containerBlocks(node))
        case .thematicBreak:
            return .rule
        case .orderedList, .unorderedList:
            return .list(list(node, isOrdered: kind == .orderedList))
        case .listItem:
            // Orphan item (no list parent): render its content.
            let inner = containerBlocks(node)
            return inner.count == 1 ? inner[0] : .quote(inner)
        case .table(let columns):
            return .table(table(node, columns: columns))
        default:
            return node.runs.isEmpty ? nil : .paragraph(node.runs)
        }
    }

    private static func list(_ node: Node, isOrdered: Bool) -> LeoMarkdownList {
        var start = 1
        if let first = node.children.first, case .listItem(let ordinal)? = first.kind { start = ordinal }
        return LeoMarkdownList(isOrdered: isOrdered, start: start, items: node.children.map(containerBlocks))
    }

    private static func table(_ node: Node, columns: [PresentationIntent.TableColumn]) -> LeoMarkdownTable {
        let count = columns.count
        let alignments: [LeoMarkdownTable.Alignment] = columns.map {
            switch $0.alignment {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        func cells(_ row: Node) -> [[LeoMarkdownRun]] {
            var out = [[LeoMarkdownRun]](repeating: [], count: count)
            for cell in row.children {
                if case .tableCell(let index)? = cell.kind, index >= 0, index < count { out[index] = cell.runs }
            }
            return out
        }
        let header = node.children.first { $0.kind == .tableHeaderRow }.map(cells) ?? [[LeoMarkdownRun]](repeating: [], count: count)
        let rows = node.children.filter { if case .tableRow? = $0.kind { true } else { false } }.map(cells)
        return LeoMarkdownTable(alignments: alignments, header: header, rows: rows)
    }
}
