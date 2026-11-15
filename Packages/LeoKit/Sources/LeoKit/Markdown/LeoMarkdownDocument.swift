import Foundation

/// Platform-neutral Markdown block model. Parsing never throws: input the
/// parser can't take becomes a single plain paragraph.
public struct LeoMarkdownDocument: Equatable, Sendable {
    public let blocks: [LeoMarkdownBlock]

    public init(blocks: [LeoMarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ markdown: String) -> LeoMarkdownDocument {
        LeoMarkdownDocument(blocks: LeoMarkdownParser.blocks(from: markdown))
    }
}

extension LeoMarkdownDocument {
    /// Every block including nested ones; a proxy for how many views rendering costs.
    public var blockCount: Int { blocks.reduce(0) { $0 + $1.blockCount } }

    /// Header plus body cells across all tables, nested ones included.
    public var tableCellCount: Int { blocks.reduce(0) { $0 + $1.tableCellCount } }
}

extension LeoMarkdownBlock {
    fileprivate var blockCount: Int {
        switch self {
        case .list(let list): 1 + list.items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.blockCount } }
        case .quote(let blocks): 1 + blocks.reduce(0) { $0 + $1.blockCount }
        default: 1
        }
    }

    fileprivate var tableCellCount: Int {
        switch self {
        case .table(let table): table.header.count + table.rows.reduce(0) { $0 + $1.count }
        case .list(let list): list.items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.tableCellCount } }
        case .quote(let blocks): blocks.reduce(0) { $0 + $1.tableCellCount }
        default: 0
        }
    }
}

public indirect enum LeoMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, [LeoMarkdownRun])
    case paragraph([LeoMarkdownRun])
    case list(LeoMarkdownList)
    case code(language: String?, text: String)
    case quote([LeoMarkdownBlock])
    case rule
    case table(LeoMarkdownTable)
}

public struct LeoMarkdownList: Equatable, Sendable {
    public let isOrdered: Bool
    public let start: Int
    public let items: [[LeoMarkdownBlock]]

    public init(isOrdered: Bool, start: Int, items: [[LeoMarkdownBlock]]) {
        self.isOrdered = isOrdered
        self.start = start
        self.items = items
    }
}

public struct LeoMarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public let alignments: [Alignment]
    public let header: [[LeoMarkdownRun]]
    public let rows: [[[LeoMarkdownRun]]]

    public init(alignments: [Alignment], header: [[LeoMarkdownRun]], rows: [[[LeoMarkdownRun]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

public struct LeoMarkdownRun: Equatable, Sendable {
    public struct Traits: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let emphasis = Traits(rawValue: 1 << 0)
        public static let strong = Traits(rawValue: 1 << 1)
        public static let code = Traits(rawValue: 1 << 2)
        public static let strikethrough = Traits(rawValue: 1 << 3)
        public static let image = Traits(rawValue: 1 << 4)
    }

    public let text: String
    public let traits: Traits
    public let link: URL?

    public init(text: String, traits: Traits = [], link: URL? = nil) {
        self.text = text
        self.traits = traits
        self.link = link
    }
}
