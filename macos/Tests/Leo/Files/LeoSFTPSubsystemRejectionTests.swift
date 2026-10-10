import Foundation
import Testing

@testable import Ghostty

/// Server stderr is untrusted: the canonical rejection line is matched on raw
/// bytes, one line at a time, so bytes elsewhere in the capture can neither
/// hide a complete canonical line nor make a noncanonical one count.
struct LeoSFTPSubsystemRejectionTests {
    private struct Capture: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        var isTruncated = false

        var testDescription: String { name }
    }

    private static let canonical = "subsystem request failed on channel 0"
    private static let invalidBytes: [UInt8] = [0xFF, 0xFE]

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test(arguments: [
        Capture(name: "canonical line, then an invalid-byte line", bytes: ascii(canonical + "\n") + invalidBytes + ascii(" junk\n")),
        Capture(name: "invalid-byte line, then the canonical line", bytes: invalidBytes + ascii(" junk\n" + canonical + "\n")),
        Capture(name: "CRLF-terminated canonical line", bytes: ascii(canonical + "\r\n")),
        Capture(name: "unterminated final line, not truncated", bytes: ascii(canonical)),
        Capture(name: "multi-digit channel", bytes: ascii("subsystem request failed on channel 12\n")),
        Capture(name: "canonical line before a truncated tail", bytes: ascii(canonical + "\nxx"), isTruncated: true),
        Capture(name: "canonical line before a sequence cut mid-character", bytes: ascii(canonical + "\nx") + [0xC3], isTruncated: true)
    ])
    private func recognizes(_ capture: Capture) {
        #expect(LeoSFTPSubsystemRejection.isCanonical(in: Data(capture.bytes), isTruncated: capture.isTruncated))
    }

    @Test(arguments: [
        Capture(name: "canonical final segment when truncated", bytes: ascii(canonical), isTruncated: true),
        Capture(name: "invalid byte after the digits", bytes: ascii(canonical) + [0xFF, 0x0A]),
        Capture(name: "invalid byte before the prefix", bytes: [0xFF] + ascii(canonical + "\n")),
        Capture(name: "invalid byte among the digits", bytes: ascii("subsystem request failed on channel 1") + [0xFF] + ascii("2\n")),
        Capture(name: "empty channel", bytes: ascii("subsystem request failed on channel \n")),
        Capture(name: "Arabic-Indic digit", bytes: ascii("subsystem request failed on channel ٠\n")),
        Capture(name: "fullwidth digit", bytes: ascii("subsystem request failed on channel ０\n")),
        Capture(name: "leading space", bytes: ascii(" " + canonical + "\n")),
        Capture(name: "two trailing carriage returns", bytes: ascii(canonical + "\r\r\n")),
        Capture(name: "embedded NUL", bytes: ascii("subsystem request failed on channel 0") + [0x00] + ascii("\n")),
        Capture(name: "no output", bytes: []),
        Capture(name: "text after the channel", bytes: ascii(canonical + " during initialization\n")),
        Capture(name: "different diagnostic", bytes: ascii("fatal: subsystem request failed during initialization\n"))
    ])
    private func rejects(_ capture: Capture) {
        #expect(!LeoSFTPSubsystemRejection.isCanonical(in: Data(capture.bytes), isTruncated: capture.isTruncated))
    }
}
