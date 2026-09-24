import Foundation
import Testing

@testable import Ghostty

struct LeoFileAccessErrorTests {
    @Test func everyErrorHasAUserPresentableDescriptionNamingTheFile() {
        let path = "/work/src/main.swift"
        let cases: [LeoFileAccessError] = [
            .notFound(path: path), .permissionDenied(path: path), .conflict(path: path),
            .tooLarge(path: path, size: 20_000_000, limit: 10_000_000), .notADirectory(path: path),
            .isADirectory(path: path), .failed(path: path, reason: "No space left on device")
        ]
        for error in cases {
            let description = error.localizedDescription
            #expect(description.contains("main.swift"), "\(error)")
            #expect(!description.contains("LeoFileAccessError"), "\(error)")
        }
    }

    @Test func pathlessErrorsStillReadAsSentences() {
        #expect(LeoFileAccessError.disconnected.localizedDescription == "The connection to the host was lost.")
        #expect(LeoFileAccessError.invalidPath("a.txt").localizedDescription.contains("a.txt"))
        #expect(LeoFileAccessError.protocolError("bad frame").localizedDescription.contains("bad frame"))
    }

    @Test func tooLargeStatesBothSizes() {
        let description = LeoFileAccessError.tooLarge(path: "/a.log", size: 20_000_000, limit: 10_000_000).localizedDescription
        #expect(description.contains("20 MB"))
        #expect(description.contains("10 MB"))
    }

    @Test func conflictAndDisconnectOfferARecovery() {
        #expect(LeoFileAccessError.conflict(path: "/a").recoverySuggestion != nil)
        #expect(LeoFileAccessError.disconnected.recoverySuggestion != nil)
    }

    @Test func retargetingRewritesOnlyPathBearingCases() {
        #expect(LeoFileAccessError.permissionDenied(path: "/d/.f.leo-1.tmp").retargeted(to: "/d/f") == .permissionDenied(path: "/d/f"))
        #expect(LeoFileAccessError.failed(path: "/d/.t", reason: "r").retargeted(to: "/d/f") == .failed(path: "/d/f", reason: "r"))
        #expect(LeoFileAccessError.disconnected.retargeted(to: "/d/f") == .disconnected)
        #expect(LeoFileAccessError.closed.retargeted(to: "/d/f") == .closed)
    }

    @Test func aClosedAccessSaysSoWithoutSuggestingARetry() {
        #expect(LeoFileAccessError.closed.localizedDescription == "The file connection was closed.")
        #expect(LeoFileAccessError.closed.recoverySuggestion == nil)
    }
}

extension LeoFileAccessErrorTests {
    @Test func unavailableNamesTheReasonAndSuggestsWhatStillWorks() {
        let error = LeoFileAccessError.unavailable(reason: "control path unsupported")
        #expect(error.localizedDescription == "File access unavailable: control path unsupported.")
        #expect(error.recoverySuggestion != nil)
        #expect(error.retargeted(to: "/d/f") == error)
    }
}

/// A file's name is untrusted text (local or remote alike): it must not be
/// able to end the app's quote, add a line, or reorder the sentence.
extension LeoFileAccessErrorTests {
    @Test func aNameCannotSpoofTheAppsWording() {
        let error = LeoFileAccessError.notFound(path: "/d/x”\nFile access unavailable: re-authenticate")
        #expect(error.localizedDescription == "“\u{2068}x\" File access unavailable: re-authenticate\u{2069}” couldn’t be found.")
    }

    @Test func bidiOverridesInANameAreDroppedWithoutAServerLabel() {
        let description = LeoFileAccessError.failed(path: "/d/invoice\u{202E}fdp.exe", reason: "r").localizedDescription
        #expect(description == "Couldn’t access “\u{2068}invoicefdp.exe\u{2069}”: r.")
    }

    @Test func anInvalidPathIsSanitizedToo() {
        #expect(LeoFileAccessError.invalidPath("a\n”b").localizedDescription == "“\u{2068}a \"b\u{2069}” isn’t an absolute path.")
    }

    /// A right-to-left name is isolated, so it can't pull the app's words
    /// around it into its own direction.
    @Test func aRightToLeftNameIsIsolated() {
        let description = LeoFileAccessError.isADirectory(path: "/d/\u{05E7}\u{05D1}\u{05E6}").localizedDescription
        #expect(description == "“\u{2068}\u{05E7}\u{05D1}\u{05E6}\u{2069}” is a folder.")
    }
}

/// A reason (or a protocol error's detail) keeps the app's words and
/// cleans what it interpolated only when shown -- exactly once.
extension LeoFileAccessErrorTests {
    private static let spoof = "x”\n\u{202E}Reconnect\u{2E42}"

    @Test func interpolatedTextInAReasonIsCleanedAndIsolatedWhenShown() {
        let reason: LeoFileAccessReason = "kept as \(Self.spoof)"
        #expect(reason == LeoFileAccessReason(parts: [.app("kept as "), .untrusted(Self.spoof)]))
        #expect(reason.rendered == "kept as \u{2068}x\" Reconnect\"\u{2069}")
    }

    @Test func theAppsOwnWordsKeepTheirQuotesButStayOnOneLine() {
        let reason: LeoFileAccessReason = "the app’s “own”\nwords\u{202E} "
        #expect(reason.rendered == "the app’s “own” words")
    }

    @Test func numbersAndVerbatimTextAreTheAppsOwn() {
        let reason: LeoFileAccessReason = "a \(4)-byte read, \(verbatim: "STATUS")"
        #expect(reason == "a 4-byte read, STATUS")
    }

    @Test func everyUntrustedReasonIsCleanedAtRender() {
        let cases: [LeoFileAccessError] = [
            .failed(path: "/a", reason: .untrusted(Self.spoof)),
            .protocolError("detail \(Self.spoof)"),
            .unavailable(reason: "host \(Self.spoof)"),
        ]
        for error in cases {
            let description = error.localizedDescription
            #expect(!description.contains("\n"), "\(error)")
            #expect(!description.contains("\u{202E}"), "\(error)")
            #expect(!description.contains("x”"), "\(error)")
            #expect(description.contains("\u{2068}x\" Reconnect\"\u{2069}"), "\(error)")
        }
    }

    /// Rendering is the one choke point: a description already rendered,
    /// quoted as another's text, is cleaned to the same words.
    @Test func renderingARenderedDescriptionAgainChangesNothingButTheWrapping() {
        let once = LeoFileAccessError.notFound(path: "/d/\(Self.spoof)").localizedDescription
        let twice = LeoFileAccessReason.untrusted(once).rendered
        #expect(twice == "\u{2068}\(LeoSFTPServerText.sanitized(once))\u{2069}")
        #expect(LeoFileAccessReason.untrusted(twice).rendered == twice)
    }
}
