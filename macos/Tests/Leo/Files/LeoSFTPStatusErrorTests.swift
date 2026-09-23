import Foundation
import Testing

@testable import Ghostty

/// How an SFTP v3 STATUS becomes a `LeoFileAccessError`: as specific as
/// the code allows, with the server's own message when it says more than
/// the code's name (OpenSSH only ever sends the name, e.g. "Failure").
struct LeoSFTPStatusErrorTests {
    private let path = "/srv/notes.txt"

    private func error(_ code: LeoSFTPStatusCode, _ message: String = "", path: String? = nil) -> LeoFileAccessError {
        LeoSFTPClient.error(for: LeoSFTPStatus(code: code, message: message), path: path ?? self.path)
    }

    @Test func noSuchFileAndPermissionDeniedMapToTheirOwnCases() {
        #expect(error(.noSuchFile, "No such file") == .notFound(path: path))
        #expect(error(.permissionDenied, "Permission denied") == .permissionDenied(path: path))
    }

    /// A server that explains itself (not OpenSSH) is quoted, like strerror
    /// is locally.
    @Test(arguments: [LeoSFTPStatusCode.failure, .badMessage, .unsupported, .other(42)])
    func aServersOwnMessageIsSurfaced(_ code: LeoSFTPStatusCode) {
        #expect(error(code, "No space left on device") == .failed(path: path, reason: LeoSFTPServerText.quoted("No space left on device")))
    }

    @Test func surroundingWhitespaceAndATrailingPeriodAreTrimmed() {
        #expect(error(.failure, "  Disk quota exceeded.\n") == .failed(path: path, reason: LeoSFTPServerText.quoted("Disk quota exceeded")))
    }

    /// The bare code name adds nothing ("Couldn’t access “x”: Failure."),
    /// so each code gets a sentence of its own instead.
    @Test(arguments: [
        (LeoSFTPStatusCode.failure, "Failure", "the server couldn’t complete the operation and gave no reason"),
        (.failure, "", "the server couldn’t complete the operation and gave no reason"),
        (.badMessage, "Bad message", "the server rejected the request as malformed"),
        (.unsupported, "Operation unsupported", "the server doesn’t support this operation"),
        (.unsupported, "", "the server doesn’t support this operation"),
        (.other(42), "Unknown error", "the server reported error 42"),
    ])
    func aBareCodeNameGetsASpecificSentence(_ code: LeoSFTPStatusCode, _ message: String, _ reason: String) {
        #expect(error(code, message) == .failed(path: path, reason: "\(verbatim: reason)"))
    }

    /// OpenSSH's sftp-server sends BAD_MESSAGE for ENAMETOOLONG.
    @Test func aBadMessageForAnOverlongNameSaysSoLikeTheLocalError() {
        let component = "/srv/" + String(repeating: "n", count: 256)
        let whole = "/srv" + String(repeating: "/d", count: 512)
        #expect(error(.badMessage, "Bad message", path: component) == .failed(path: component, reason: "File name too long"))
        #expect(error(.badMessage, "Bad message", path: whole) == .failed(path: whole, reason: "File name too long"))
    }

    @Test func connectionCodesAreDisconnected() {
        #expect(error(.noConnection, "No connection") == .disconnected)
        #expect(error(.connectionLost, "Connection lost") == .disconnected)
    }

    @Test func successCodesWhereAFailureWasDueAreProtocolErrors() {
        #expect(error(.ok, "Success") == .protocolError("unexpected status ok"))
        #expect(error(.eof) == .protocolError("unexpected status eof"))
    }
}
