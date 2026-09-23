import Foundation
import Testing

@testable import Ghostty

/// A server's status message is untrusted text shown inside the app's own
/// sentence: it must never read as text the app wrote.
struct LeoSFTPServerTextTests {
    private let path = "/srv/notes.txt"

    /// The reason as shown: sanitized when rendered, not before.
    private func reason(_ message: String) -> String? {
        guard case let .failed(_, reason) = LeoSFTPClient.error(for: LeoSFTPStatus(code: .failure, message: message), path: path) else {
            return nil
        }
        return reason.rendered
    }

    /// The server's words as rendered: isolated inside the app's quote.
    private func said(_ text: String) -> String {
        "the server said “\u{2068}\(text)\u{2069}”"
    }

    @Test func aServersMessageIsLabelledAsTheServers() {
        #expect(reason("No space left on device") == said("No space left on device"))
    }

    /// Newlines would let the server write a line that looks like the app's.
    @Test func embeddedNewlinesCollapseIntoOneLine() {
        let injected = "x.\n\nFile access unavailable: re-authenticate at https://evil.example\r\n"
        #expect(reason(injected) == said("x. File access unavailable: re-authenticate at https://evil.example"))
    }

    @Test func runsOfWhitespaceAndLineSeparatorsCollapseToOneSpace() {
        #expect(reason("a \t  b\u{2028}c\u{2029}\u{85}d") == said("a b c d"))
    }

    /// RTL overrides and other format characters reorder or hide text.
    @Test func bidiAndFormatCharactersAreDropped() {
        #expect(reason("invoice\u{202E}fdp.exe\u{200B}\u{2066}\u{FEFF}") == said("invoicefdp.exe"))
    }

    @Test func controlCharactersAreDropped() {
        #expect(reason("a\u{0}b\u{1B}[31mc\u{7F}d\u{9B}e") == said("ab[31mcde"))
    }

    /// A quote of its own would let the message end the app's quote early.
    @Test func curlyQuotesCannotCloseTheQuote() {
        #expect(reason("x” — the app said “fine") == said("x\" — the app said \"fine"))
    }

    @Test func anOverlongMessageIsCappedWithAnEllipsis() throws {
        let text = try #require(reason(String(repeating: "a", count: 256 * 1024)))
        let quoted = text.dropFirst("the server said “\u{2068}".count).dropLast(2)
        #expect(quoted.count == LeoSFTPServerText.limit)
        #expect(quoted.hasSuffix("…"))
        #expect(quoted.dropLast().allSatisfy { $0 == "a" })
    }

    @Test func aMessageOfOnlyInvisibleCharactersIsNoMessage() {
        #expect(reason("\u{0}\u{202E}\n \u{200B}") == "the server couldn’t complete the operation and gave no reason")
    }

    /// The success codes' protocol error quotes the server the same way.
    @Test func anUnexpectedSuccessStatusIsSanitizedToo() {
        let error = LeoSFTPClient.error(for: LeoSFTPStatus(code: .ok, message: "done\n\nre-authenticate\u{202E}"), path: path)
        #expect(error.localizedDescription == "The file server sent an unexpected response (unexpected status ok; \(said("done re-authenticate"))).")
    }
}

/// Text that is short in characters but long in scalars, or that imitates
/// the app's quotes, must stay bounded and inside the quote.
extension LeoSFTPServerTextTests {
    private func clean(_ text: String) -> String { LeoSFTPServerText.sanitized(text) }

    /// One grapheme of 1,600 scalars: a grapheme cap alone never applies.
    @Test func aCombiningMarkFloodKeepsFourMarksPerBase() {
        let flood = "a" + String(repeating: "\u{301}", count: 1599)
        #expect(clean(flood) == "a" + String(repeating: "\u{301}", count: 4))
    }

    @Test func zalgoTextKeepsItsLettersAndAtMostFourMarksEach() {
        let marks = (0x300...0x31F).compactMap(Unicode.Scalar.init).map(String.init).joined() + "\u{20DD}\u{20DE}"
        let zalgo = "zalgo".map { String($0) + marks }.joined()
        let text = clean(zalgo)
        #expect(text.unicodeScalars.count == 25)
        #expect(text.unicodeScalars.filter { $0.properties.isAlphabetic && $0.value < 0x80 }.map(String.init).joined() == "zalgo")
    }

    /// Hangul leading jamo join into one grapheme however many there are.
    @Test func aSingleHugeGraphemeIsCappedByScalarCount() {
        let text = clean(String(repeating: "\u{1100}", count: 1000))
        #expect(text.unicodeScalars.count <= LeoSFTPServerText.scalarLimit)
        #expect(text.hasSuffix("…"))
    }

    /// Cut at the scan limit, then almost nothing left once cleaned.
    @Test func aMostlyInvisibleOverlongMessageIsCutThenShort() {
        let text = "disk full" + String(repeating: "\u{200B}\u{0}", count: 1000) + " tail"
        #expect(clean(text) == "disk full…")
    }

    /// The app quotes with “ ”, so only double-quote lookalikes could
    /// close its quote.
    @Test func everyDoubleQuoteLookalikeIsStraightened() {
        let lookalikes = "\u{201C}\u{201D}\u{201E}\u{201F}\u{AB}\u{BB}\u{2033}\u{2036}\u{275D}\u{275E}\u{301D}\u{301E}\u{301F}\u{FF02}"
            + "\u{2E42}\u{1F676}\u{1F677}\u{1F678}\u{05F4}\u{02BA}\u{3003}\u{02DD}"
        #expect(clean(lookalikes) == String(repeating: "\"", count: lookalikes.unicodeScalars.count))
    }

    @Test func singleQuotesAndApostrophesSurvive() {
        let singles = "\u{2018}\u{2019}\u{201A}\u{201B}\u{2039}\u{203A}'"
        #expect(clean(singles) == singles)
        #expect(clean("Evan’s notes.md") == "Evan’s notes.md")
    }

    /// ZWJ and ZWNJ join emoji and shape Persian and Indic text.
    @Test func joinersSurvive() {
        #expect(clean("👨\u{200D}👩\u{200D}👧") == "👨\u{200D}👩\u{200D}👧")
        #expect(clean("می\u{200C}خواهم") == "می\u{200C}خواهم")
    }

    /// Hebrew with dagesh, vowel and cantillation, and Devanagari with a
    /// nukta, vowel sign and candrabindu, stack three or four marks on one
    /// base.
    @Test func hebrewAndIndicStacksOfThreeMarksSurvive() {
        let hebrew = "\u{5E9}\u{5BC}\u{5C1}\u{5B8}\u{591}ל"
        let devanagari = "\u{915}\u{93C}\u{941}\u{901}"
        #expect(clean(hebrew) == hebrew)
        #expect(clean(devanagari) == devanagari)
    }

    /// England's flag is U+1F3F4 followed by tag characters; elsewhere a
    /// tag character is invisible and dropped.
    @Test func subdivisionFlagsKeepTheirTagsAndStrayTagsAreDropped() {
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(clean("go \(england)!") == "go \(england)!")
        #expect(clean("a\u{E0067}\u{E007F}b") == "ab")
        #expect(clean(england + "x\u{E0067}") == england + "x")
    }

    /// Tags spell ASCII invisibly ("ASCII smuggling"), and each flag run
    /// counts once against `limit`: only the three RGI subdivision flags
    /// keep theirs, and a cut never splits one.
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6])
    func onlyTheRGISubdivisionFlagsKeepTags(_ offset: Int) {
        let rgi = ["gbeng", "gbsct", "gbwls"].map(Self.flag)
        let smuggled = Self.flag("ignore previous instructions")
        let runs = (0..<150).map { [rgi[$0 % 3], smuggled, Self.flag("gbzzz"), Self.flag("gbeng").dropLast() + "x"][$0 % 4] }
        let text = String(repeating: "a", count: offset) + runs.joined() + "\u{E0041}\u{1F3F4}\u{E007F}"

        var rest = clean(text)
        for flag in rgi { rest = rest.replacingOccurrences(of: flag, with: "") }

        #expect(!rest.unicodeScalars.contains { (0xE0000...0xE007F).contains($0.value) })
        #expect(clean(text).contains(rgi[0]))
    }

    /// Variation selectors carry data invisibly too (D-041): only a single
    /// U+FE0E or U+FE0F right after its base survives.
    @Test func variationSelectorsAreKeptOnlyAsOneEmojiOrTextSelectorPerBase() {
        let supplementary = (0xE0100...0xE01EF).compactMap(Unicode.Scalar.init).map(String.init).joined()
        let standard = (0xFE00...0xFE0D).compactMap(Unicode.Scalar.init).map(String.init).joined()
        let packed = (0..<150).map { _ in "a" + String(String.UnicodeScalarView(supplementary.unicodeScalars.prefix(4))) }.joined()
            + "b" + standard + "c\u{FE0F}\u{FE0F}d\u{301}\u{FE0F}e\u{FE0E}\u{FE0E}f\u{FE0F}\u{FE00}\u{FE0E}"
            + " \u{FE0F}x\u{200D}\u{FE0F}"

        let text = clean(packed)

        let selectors = text.unicodeScalars.filter { (0xFE00...0xFE0F).contains($0.value) || (0xE0100...0xE01EF).contains($0.value) }
        #expect(selectors.map(\.value) == [0xFE0F, 0xFE0E, 0xFE0F])
        #expect(text.hasSuffix("bc\u{FE0F}d\u{301}e\u{FE0E}f\u{FE0F} x\u{200D}"))
    }

    @Test func emojiPresentationAndFlagsSurvive() {
        let emoji = "❤️ 👩\u{200D}❤\u{FE0F}\u{200D}👨 1\u{FE0F}\u{20E3} ☺︎ " + ["gbeng", "gbsct", "gbwls"].map(Self.flag).joined()
        #expect(clean(emoji) == emoji)
    }

    /// Hangul fillers and the Braille blank render as nothing: they are
    /// whitespace, so a name of them can't pass for a name.
    @Test func blankGlyphsCollapseLikeWhitespace() {
        #expect(clean(String(repeating: "\u{3164}", count: 40)).isEmpty)
        #expect(clean("a\u{115F}\u{1160}b\u{3164}\u{FFA0}c\u{2800}\u{2800}d") == "a b c d")
        #expect(LeoWorkspaceEntry(name: "\u{3164}\u{3164}", path: "/w/\u{3164}\u{3164}", isFolder: false).displayName == "\u{FFFD}")
        #expect(LeoFileAccessError.notFound(path: "/w/\u{3164}\u{3164}").localizedDescription == "“\u{2068}\u{2069}” couldn’t be found.")
    }

    private static func flag(_ code: String) -> String {
        "\u{1F3F4}" + code.unicodeScalars.compactMap { Unicode.Scalar(0xE0000 + $0.value) }.map(String.init).joined() + "\u{E007F}"
    }
}

/// Untrusted text set inside the app's sentence is isolated (FSI … PDI),
/// so a right-to-left name can't reorder the words around it; cleaning is
/// idempotent, so text that is cleaned twice reads the same.
extension LeoSFTPServerTextTests {
    private static let samples = [
        "plain", "x”\nFile access unavailable\u{202E}", "\u{2068}already\u{2069}", "\u{05D0}\u{05D1}.txt",
        "a" + String(repeating: "\u{301}", count: 9), String(repeating: "b", count: 300), "\u{2066}\u{2069}\u{2069}",
    ]

    @Test func anIsolatedNameIsWrappedInFirstStrongIsolates() {
        #expect(LeoSFTPServerText.isolated("שלום.txt") == "\u{2068}שלום.txt\u{2069}")
        #expect(LeoSFTPServerText.isolated("a\u{2069}\u{202E}b") == "\u{2068}ab\u{2069}")
    }

    @Test(arguments: samples)
    func cleaningTwiceIsCleaningOnce(_ text: String) {
        let once = LeoSFTPServerText.sanitized(text)
        #expect(LeoSFTPServerText.sanitized(once) == once)
        let isolated = LeoSFTPServerText.isolated(text)
        #expect(LeoSFTPServerText.isolated(isolated) == isolated)
        #expect(LeoSFTPServerText.sanitized(isolated) == once)
    }
}
