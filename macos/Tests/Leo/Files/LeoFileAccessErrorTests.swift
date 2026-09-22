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
    }
}
