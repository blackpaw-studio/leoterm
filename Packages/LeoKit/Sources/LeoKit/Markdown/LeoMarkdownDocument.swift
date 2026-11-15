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
