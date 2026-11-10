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

    public static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItems: [[Inline]] = []
        var listOrdered = false
        var fence: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlines(paragraph.joined(separator: " "))))
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
                blocks.append(.heading(level: level, inlines(text)))
            } else if let (ordered, text) = listItem(line) {
                flushParagraph()
                if !listItems.isEmpty, listOrdered != ordered { flushList() }
                listOrdered = ordered
                listItems.append(inlines(text))
            } else {
                flushList()
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        if let open = fence { blocks.append(.codeBlock(open.joined(separator: "\n"))) }
        flushParagraph(); flushList()
        return blocks
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

    static func inlines(_ s: String) -> [Inline] {
        var out: [Inline] = []
        var buf = ""
        let chars = Array(s)
        var i = 0

        func flush() { if !buf.isEmpty { out.append(.text(buf)); buf = "" } }
        func find(_ marker: [Character], from: Int) -> Int? {
            guard from + marker.count <= chars.count else { return nil }
            for j in from...(chars.count - marker.count) where Array(chars[j..<j + marker.count]) == marker { return j }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                flush(); out.append(.code(String(chars[i + 1..<end]))); i = end + 1
            } else if c == "*", i + 1 < chars.count, chars[i + 1] == "*",
                      let end = find(["*", "*"], from: i + 2), end > i + 2 {
                flush(); out.append(.strong(inlines(String(chars[i + 2..<end])))); i = end + 2
            } else if c == "*", let end = find(["*"], from: i + 1), end > i + 1 {
                flush(); out.append(.emphasis(inlines(String(chars[i + 1..<end])))); i = end + 1
            } else if c == "[", let close = find(["]", "("], from: i + 1), let paren = find([")"], from: close + 2),
                      !(i > 0 && chars[i - 1] == "!") {
                let label = String(chars[i + 1..<close])
                let url = String(chars[close + 2..<paren])
                flush()
                if isHTTPS(url) {
                    out.append(.link(text: inlines(label), url: url))
                } else {
                    out.append(contentsOf: inlines(label))
                }
                i = paren + 1
            } else {
                buf.append(c); i += 1
            }
        }
        flush()
        return merged(out)
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
