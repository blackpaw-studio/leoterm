import Foundation
import Testing

@testable import Ghostty

/// The highlighter runs on the main thread over up to 2M characters, so no
/// input may make a rule re-scan the text it just scanned (a backtracking
/// regex going quadratic hangs the app). Each text strings together runs
/// of units that attack one kind of rule: unterminated strings full of
/// escaped quotes, brackets that never close, list markers, keys padded
/// with spaces, and so on. Serialized: the attacks are CPU-heavy, and
/// shouldn't starve timing-sensitive suites running beside them.
@Suite(.serialized)
struct LeoSyntaxHighlighterAdversarialTests {
    /// Generous: linear rules take a few hundredths of this.
    static let bound = Duration.seconds(1)
    static let megabyte = 1_000_000

    static let units = [
        #""\"#, #"'\"#, #"`\"#, "[", "[a](", "[[a](", "<http://", "<https://a", "- ", "- a ", "a ", "a" + String(repeating: " ", count: 60),
        ": ", ": a", "# ", "*a", "**a", "_a", "__a", "1", "1e", "0x", "\"", "'", "`", "${", "$", ",a", "a =", "a:", "{a", "@a",
        "&a", "!a", "/*", "//", "\"\"\"", "'''", "~~~", "```", ">", ".", "\\", "\t", "a.b", "r\"", "- - a", "a b:",
    ]

    /// Runs of every unit in turn, each about `runLength` long, joined
    /// into lines of about `lineLength` (or one line, if nil).
    static func text(length: Int, runLength: Int, lineLength: Int?) -> String {
        var runs: [String] = []
        var total = 0
        while total < length {
            for unit in units where total < length {
                let run = String(repeating: unit, count: max(1, runLength / unit.count))
                runs.append(run)
                total += run.count
            }
        }
        let joined = runs.joined()
        guard let lineLength else { return joined }
        var lines: [Substring] = []
        var start = joined.startIndex
        while start < joined.endIndex {
            let end = joined.index(start, offsetBy: lineLength, limitedBy: joined.endIndex) ?? joined.endIndex
            lines.append(joined[start..<end])
            start = end
        }
        return lines.joined(separator: "\n")
    }

    private func time(_ text: String, _ language: LeoEditorLanguage) -> (Duration, [LeoSyntaxSpan]) {
        var spans: [LeoSyntaxSpan] = []
        let elapsed = ContinuousClock().measure {
            spans = LeoSyntaxHighlighter.spans(in: text, language: language)
        }
        return (elapsed, spans)
    }

    /// Minified JSON, a log line: one line of a megabyte. Lines this long
    /// are left plain, so this is about skipping them cheaply.
    @Test(arguments: LeoEditorLanguage.allCases)
    func aMegabyteLineHighlightsQuickly(_ language: LeoEditorLanguage) {
        let text = Self.text(length: Self.megabyte, runLength: 30_000, lineLength: nil)

        let (elapsed, spans) = time(text, language)

        #expect(elapsed < Self.bound, "\(language) took \(elapsed)")
        #expect(spans.isEmpty)
    }

    /// Each attack alone, on lines just short enough to be highlighted:
    /// this is what holds each rule to one pass. A rule that re-scans
    /// takes a quarter second or more here; one pass, a hundredth.
    @Test(arguments: LeoEditorLanguage.allCases)
    func everyAttackOnLinesAtTheLimitHighlightsQuickly(_ language: LeoEditorLanguage) {
        let limit = LeoSyntaxHighlighter.longLineLimit
        let slow = Self.units.compactMap { unit -> String? in
            let line = String(repeating: unit, count: limit / unit.count)
            let (elapsed, _) = time(Array(repeating: line, count: 4).joined(separator: "\n"), language)
            return elapsed < .milliseconds(200) ? nil : "\(unit.debugDescription) took \(elapsed)"
        }

        #expect(slow.isEmpty, "\(language): \(slow)")
    }

    @Test func linesOverTheLimitAreLeftPlainAndTheRestHighlighted() {
        let long = "let " + String(repeating: "x", count: LeoSyntaxHighlighter.longLineLimit)
        let text = "let a = 1\n\(long)\nlet b\n\(long)"
        let source = text as NSString

        let spans = LeoSyntaxHighlighter.spans(in: text, language: .swift).map { "\($0.token) \(source.substring(with: $0.range))" }

        #expect(spans == ["keyword let", "number 1", "keyword let"])
    }

    /// Exactly at the limit is still highlighted.
    @Test func aLineAtTheLimitIsHighlighted() {
        let line = "let " + String(repeating: "x", count: LeoSyntaxHighlighter.longLineLimit - 4)

        let spans = LeoSyntaxHighlighter.spans(in: line, language: .swift)

        #expect(spans.map(\.token) == [.keyword])
    }
}
