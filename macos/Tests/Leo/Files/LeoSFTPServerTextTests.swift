import Foundation
import Testing

@testable import Ghostty

/// A server's status message is untrusted text shown inside the app's own
/// sentence: it must never read as text the app wrote.
struct LeoSFTPServerTextTests {
    private let path = "/srv/notes.txt"

    private func reason(_ message: String) -> String? {
        guard case let .failed(_, reason) = LeoSFTPClient.error(for: LeoSFTPStatus(code: .failure, message: message), path: path) else {
            return nil
        }
        return reason
    }

    @Test func aServersMessageIsLabelledAsTheServers() {
        #expect(reason("No space left on device") == "the server said “No space left on device”")
    }

    /// Newlines would let the server write a line that looks like the app's.
    @Test func embeddedNewlinesCollapseIntoOneLine() {
        let injected = "x.\n\nFile access unavailable: re-authenticate at https://evil.example\r\n"
        #expect(reason(injected) == "the server said “x. File access unavailable: re-authenticate at https://evil.example”")
    }

    @Test func runsOfWhitespaceAndLineSeparatorsCollapseToOneSpace() {
        #expect(reason("a \t  b\u{2028}c\u{2029}\u{85}d") == "the server said “a b c d”")
    }

    /// RTL overrides and other format characters reorder or hide text.
    @Test func bidiAndFormatCharactersAreDropped() {
        #expect(reason("invoice\u{202E}fdp.exe\u{200B}\u{2066}\u{FEFF}") == "the server said “invoicefdp.exe”")
    }

    @Test func controlCharactersAreDropped() {
        #expect(reason("a\u{0}b\u{1B}[31mc\u{7F}d\u{9B}e") == "the server said “ab[31mcde”")
    }

    /// A quote of its own would let the message end the app's quote early.
    @Test func curlyQuotesCannotCloseTheQuote() {
        #expect(reason("x” — the app said “fine") == "the server said “x\" — the app said \"fine”")
    }

    @Test func anOverlongMessageIsCappedWithAnEllipsis() throws {
        let text = try #require(reason(String(repeating: "a", count: 256 * 1024)))
        let quoted = text.dropFirst("the server said “".count).dropLast()
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
        #expect(error == .protocolError("unexpected status ok; the server said “done re-authenticate”"))
    }
}
