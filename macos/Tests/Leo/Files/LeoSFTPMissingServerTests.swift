import Foundation
import Testing

@testable import Ghostty

/// The missing-server marker is matched on raw bytes, one line at a time, so
/// bytes elsewhere in the capture can neither hide it nor make a noncanonical
/// line count.
struct LeoSFTPMissingServerTests {
    private struct Capture: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        var isTruncated = false

        var testDescription: String { name }
    }

    private static let marker = LeoSSHCommand.missingSFTPServerMarker
    private static let invalidBytes: [UInt8] = [0xFF, 0xFE]

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test(arguments: [
        Capture(name: "marker, then an invalid-byte line", bytes: ascii(marker + "\n") + invalidBytes + ascii(" junk\n")),
        Capture(name: "invalid-byte line, then the marker", bytes: invalidBytes + ascii(" junk\n" + marker + "\n")),
        Capture(name: "CRLF-terminated marker", bytes: ascii(marker + "\r\n")),
        Capture(name: "unterminated final line, not truncated", bytes: ascii(marker)),
        Capture(name: "marker before a truncated tail", bytes: ascii(marker + "\nxx"), isTruncated: true),
        Capture(name: "marker before a sequence cut mid-character", bytes: ascii(marker + "\nx") + [0xC3], isTruncated: true)
    ])
    private func recognizes(_ capture: Capture) {
        #expect(LeoSFTPMissingServer.isMarked(in: Data(capture.bytes), isTruncated: capture.isTruncated))
    }

    @Test(arguments: [
        Capture(name: "marker as the final segment when truncated", bytes: ascii(marker), isTruncated: true),
        Capture(name: "invalid byte inside the marker line", bytes: ascii(marker) + [0xFF, 0x0A]),
        Capture(name: "invalid byte before the marker", bytes: [0xFF] + ascii(marker + "\n")),
        Capture(name: "text after the marker", bytes: ascii(marker + " (really)\n")),
        Capture(name: "text before the marker", bytes: ascii("warning: " + marker + "\n")),
        Capture(name: "two trailing carriage returns", bytes: ascii(marker + "\r\r\n")),
        Capture(name: "no output", bytes: [])
    ])
    private func rejects(_ capture: Capture) {
        #expect(!LeoSFTPMissingServer.isMarked(in: Data(capture.bytes), isTruncated: capture.isTruncated))
    }
}
