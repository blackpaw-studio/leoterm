import Foundation

/// Restricted Markdown (headings, emphasis, code, links, lists) parsed to a platform-neutral AST.
/// Links must be https; images, HTML and anything unrecognised stay plain text.
public enum LeoPluginMarkdown {
    public indirect enum Inline: Equatable, Sendable {
        case text(String)
        case emphasis([Inline])
        case strong([Inline])
        case code(String)
        case link(text: [Inline], url: String)
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, [Inline])
        case paragraph([Inline])
        case list(ordered: Bool, items: [[Inline]])
        case codeBlock(String)
    }

    /// Counts scan steps so tests can assert the parser stays linear.
    final class Work {
        var steps = 0
    }

    public static func parse(_ source: String) -> [Block] { parse(source, work: Work()) }

    static func parse(_ source: String, work: Work) -> [Block] {
        let source = capped(source)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItems: [[Inline]] = []
        var listOrdered = false
        var fence: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlines(paragraph.joined(separator: " "), work: work)))
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(ordered: listOrdered, items: listItems))
            listItems = []
        }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if fence != nil {
                if line.hasPrefix("```") {
                    blocks.append(.codeBlock(fence!.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence!.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph(); flushList()
                fence = []
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph(); flushList()
            } else if let (level, text) = heading(line) {
                flushParagraph(); flushList()
                blocks.append(.heading(level: level, inlines(text, work: work)))
            } else if let (ordered, text) = listItem(line) {
                flushParagraph()
                if !listItems.isEmpty, listOrdered != ordered { flushList() }
                listOrdered = ordered
                listItems.append(inlines(text, work: work))
            } else {
                flushList()
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        if let open = fence { blocks.append(.codeBlock(open.joined(separator: "\n"))) }
        flushParagraph(); flushList()
        return blocks
    }

    /// `source` cut to `LeoPluginFrameLimits.maxMarkdownBytes` UTF-8 bytes, never mid-character.
    private static func capped(_ source: String) -> String {
        let limit = LeoPluginFrameLimits.maxMarkdownBytes
        guard source.utf8.count > limit else { return source }
        var bytes = 0
        let kept = source.unicodeScalars.prefix { bytes += UTF8.width($0); return bytes <= limit }
        return String(String.UnicodeScalarView(kept))
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let t = line.drop { $0 == " " }
        if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " {
            return (false, String(t.dropFirst(2)))
        }
        let digits = t.prefix { $0.isNumber && $0.isASCII }
        if !digits.isEmpty, t.dropFirst(digits.count).hasPrefix(". ") {
            return (true, String(t.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: Inline

    static func inlines(_ s: String, work: Work = Work()) -> [Inline] {
        var out: [Inline] = []
        var buf = ""
        let chars = Array(s)
        let next = NextMarkers(chars, work: work)
        var i = 0

        func flush() { if !buf.isEmpty { out.append(.text(buf)); buf = "" } }

        while i < chars.count {
            work.steps += 1
            let c = chars[i]
            if c == "`", let end = next.backtick(from: i + 1), end > i + 1 {
                flush(); out.append(.code(String(chars[i + 1..<end]))); i = end + 1
            } else if c == "*", i + 1 < chars.count, chars[i + 1] == "*",
                      let end = next.doubleStar(from: i + 2), end > i + 2 {
                flush(); out.append(.strong(inlines(String(chars[i + 2..<end]), work: work))); i = end + 2
            } else if c == "*", let end = next.star(from: i + 1), end > i + 1 {
                flush(); out.append(.emphasis(inlines(String(chars[i + 1..<end]), work: work))); i = end + 1
            } else if c == "[", let close = next.closeBracketParen(from: i + 1), let paren = next.closeParen(from: close + 2),
                      !(i > 0 && chars[i - 1] == "!") {
                let label = String(chars[i + 1..<close])
                let url = String(chars[close + 2..<paren])
                flush()
                if isHTTPS(url) {
                    out.append(.link(text: inlines(label, work: work), url: url))
                } else {
                    out.append(contentsOf: inlines(label, work: work))
                }
                i = paren + 1
            } else {
                buf.append(c); i += 1
            }
        }
        flush()
        return merged(out)
    }

    /// For each position, the index of the next marker at or after it, built in
    /// one backwards pass so every lookup is O(1) and an unmatched opener
    /// costs nothing more than the pass itself.
    private struct NextMarkers {
        private let backticks: [Int]
        private let stars: [Int]
        private let doubleStars: [Int]
        private let bracketParens: [Int]
        private let parens: [Int]
        private let count: Int

        init(_ chars: [Character], work: Work) {
            let n = chars.count
            count = n
            var backticks = [Int](repeating: n, count: n + 1)
            var stars = backticks, doubleStars = backticks, bracketParens = backticks, parens = backticks
            for j in stride(from: n - 1, through: 0, by: -1) {
                work.steps += 1
                backticks[j] = chars[j] == "`" ? j : backticks[j + 1]
                stars[j] = chars[j] == "*" ? j : stars[j + 1]
                doubleStars[j] = chars[j] == "*" && j + 1 < n && chars[j + 1] == "*" ? j : doubleStars[j + 1]
                bracketParens[j] = chars[j] == "]" && j + 1 < n && chars[j + 1] == "(" ? j : bracketParens[j + 1]
                parens[j] = chars[j] == ")" ? j : parens[j + 1]
            }
            self.backticks = backticks; self.stars = stars; self.doubleStars = doubleStars
            self.bracketParens = bracketParens; self.parens = parens
        }

        func backtick(from: Int) -> Int? { lookup(backticks, from) }
        func star(from: Int) -> Int? { lookup(stars, from) }
        func doubleStar(from: Int) -> Int? { lookup(doubleStars, from) }
        func closeBracketParen(from: Int) -> Int? { lookup(bracketParens, from) }
        func closeParen(from: Int) -> Int? { lookup(parens, from) }

        private func lookup(_ table: [Int], _ from: Int) -> Int? {
            guard from <= count else { return nil }
            let hit = table[from]
            return hit < count ? hit : nil
        }
    }

    private static func isHTTPS(_ s: String) -> Bool {
        guard let u = URLComponents(string: s), u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty else { return false }
        return true
    }

    /// Joins adjacent text runs so plain-text fallbacks read as one string.
    private static func merged(_ xs: [Inline]) -> [Inline] {
        xs.reduce(into: []) { acc, x in
            if case .text(let b) = x, case .text(let a)? = acc.last { acc[acc.count - 1] = .text(a + b) } else { acc.append(x) }
        }
    }
}
