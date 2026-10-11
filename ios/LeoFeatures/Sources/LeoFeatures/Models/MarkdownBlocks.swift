import Foundation

/// A Markdown source split into top-level blocks that remember their
/// 1-based source lines, so a viewer can render each block and still find
/// the one an agent's `line` points into. Blank lines separate blocks;
/// fenced code is one block (its text without the fences), as is each ATX
/// heading. A `---`/`===` line right under prose stays with it (setext).
public struct MarkdownBlocks: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case prose
            case code(language: String?)
        }

        public let kind: Kind
        /// Source lines, fences included.
        public let lines: ClosedRange<Int>
        /// Prose as written; code without its fences.
        public let text: String

        /// The first source line of a code block's text (after its fence).
        public var firstContentLine: Int {
            if case .code = kind { return lines.lowerBound + 1 }
            return lines.lowerBound
        }
    }

    public let blocks: [Block]

    public init(_ source: String) {
        blocks = Self.split(source.components(separatedBy: "\n"))
    }

    /// The block holding `line`; a blank line between blocks belongs to the
    /// next one. Nil past the end.
    public func blockIndex(containing line: Int) -> Int? {
        blocks.firstIndex { $0.lines.upperBound >= line }
    }

    private static func split(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var proseStart = 0
        var index = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            blocks.append(Block(kind: .prose, lines: proseStart...(proseStart + prose.count - 1), text: prose.joined(separator: "\n")))
            prose = []
        }

        while index < lines.count {
            let line = lines[index]
            let number = index + 1
            if let fence = Fence(line) {
                flushProse()
                var end = index + 1
                while end < lines.count, !fence.isClosed(by: lines[end]) { end += 1 }
                let body = lines[(index + 1)..<min(end, lines.count)]
                let last = min(end, lines.count - 1)
                blocks.append(Block(kind: .code(language: fence.language), lines: number...(last + 1), text: body.joined(separator: "\n")))
                index = last + 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushProse()
            } else if isHeading(line) {
                flushProse()
                blocks.append(Block(kind: .prose, lines: number...number, text: line))
            } else if isThematicBreak(trimmed), prose.isEmpty {
                blocks.append(Block(kind: .prose, lines: number...number, text: line))
            } else {
                if prose.isEmpty { proseStart = number }
                prose.append(line)
            }
            index += 1
        }
        flushProse()
        return blocks
    }

    private static func isHeading(_ line: String) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return false }
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = body.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let mark = marks.first, "-*_=".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// A ``` or ~~~ fence (indented at most three spaces).
    private struct Fence {
        let character: Character
        let length: Int
        let language: String?

        init?(_ line: String) {
            let body = line.drop { $0 == " " }
            guard line.count - body.count <= 3, let first = body.first, first == "`" || first == "~" else { return nil }
            let run = body.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }
            character = first
            length = run.count
            language = info.split(separator: " ").first.map(String.init)
        }

        func isClosed(by line: String) -> Bool {
            let body = line.drop { $0 == " " }
            guard line.count - body.count <= 3 else { return false }
            let run = body.prefix { $0 == character }
            return run.count >= length && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
        }
    }
}
