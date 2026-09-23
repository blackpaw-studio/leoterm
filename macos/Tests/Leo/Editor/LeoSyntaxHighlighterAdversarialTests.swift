import Foundation
import Testing

@testable import Ghostty

/// The highlighter runs on the main thread over up to 2M characters, so no
/// input may make a rule re-scan the text it just scanned (a backtracking
/// regex going quadratic hangs the app). Each text strings together runs
/// of units that attack one kind of rule: unterminated strings full of
/// escaped quotes, brackets that never close, list markers, keys padded
/// with spaces, and so on. The regex engine's work is counted in ticks
/// (see `LeoRegexWorkCounter`), not timed, so a loaded machine can't fail
/// these and a fast one can't hide a regression. Serialized: the attacks
/// are CPU-heavy, and shouldn't starve suites running beside them.
@Suite(.serialized)
struct LeoSyntaxHighlighterAdversarialTests {
    static let megabyte = 1_000_000

    /// One tick (about ten thousand engine steps) per this many characters:
    /// every attack, in every language, does a third of this or less. A
    /// rule that re-scans a line at the limit from each place it could
    /// start costs dozens of times more.
    static let charactersPerTick = 128

    static func budget(for text: String) -> Int { text.utf16.count / charactersPerTick }

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

    /// Minified JSON, a log line: one line of a megabyte. Lines this long
    /// are left plain, so this is about skipping them without a scan.
    @Test(arguments: LeoEditorLanguage.allCases)
    func aMegabyteLineIsSkippedWithoutScanning(_ language: LeoEditorLanguage) {
        let text = Self.text(length: Self.megabyte, runLength: 30_000, lineLength: nil)
        let counter = LeoRegexWorkCounter()

        let spans = LeoSyntaxHighlighter.spans(in: text, language: language, matcher: counter.matcher)

        #expect(counter.scannedCharacters == 0, "\(language) scanned \(counter.scannedCharacters) characters")
        #expect(spans.isEmpty)
    }

    /// Each attack alone, on lines just short enough to be highlighted:
    /// this is what holds each rule to one pass. The counted matcher must
    /// also find exactly what Foundation's does, or it isn't counting the
    /// regex the app runs.
    @Test(arguments: LeoEditorLanguage.allCases)
    func everyAttackOnLinesAtTheLimitStaysInOnePass(_ language: LeoEditorLanguage) {
        let limit = LeoSyntaxHighlighter.longLineLimit
        let problems = Self.units.compactMap { unit -> String? in
            let line = String(repeating: unit, count: limit / unit.count)
            let text = Array(repeating: line, count: 4).joined(separator: "\n")
            let counter = LeoRegexWorkCounter()
            let spans = LeoSyntaxHighlighter.spans(in: text, language: language, matcher: counter.matcher)
            if spans != LeoSyntaxHighlighter.spans(in: text, language: language) {
                return "\(unit.debugDescription) counted spans differ from Foundation's"
            }
            let budget = Self.budget(for: text)
            return counter.ticks <= budget ? nil : "\(unit.debugDescription) took \(counter.ticks) ticks (budget \(budget))"
        }

        #expect(problems.isEmpty, "\(language): \(problems)")
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
