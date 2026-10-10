import Foundation
import Testing

@testable import Ghostty

/// D-355 at the transport level: a lost RENAME is never reported as a
/// success or a plain failure, never retried, and never cleaned up by name.
struct LeoSFTPPublishTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func aRenameCommittedButReplyLostIsIndeterminate() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let relay = LeoSFTPRenameLossRelay(losing: .reply)
        let access = LeoFileAccessor.sftp(launcher: relay)
        let payload = leoPatternData(count: 3 * 32 * 1024 + 7)
        let path = sandbox.path("report.bin")

        await #expect(throws: LeoFileAccessError.indeterminate(path: path)) {
            try await access.create(payload, at: path)
        }
        await access.close()

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == payload)
        #expect(try sandbox.names() == ["report.bin"], "no staging is left once the server published it")
        #expect(relay.renames == 1)
        #expect(relay.removesAfterRename == 0)
        #expect(relay.launches == 1, "never reconnects to retry")
    }

    @Test(.timeLimit(.minutes(1)))
    func aRenameLostBeforeTheServerSawItIsIndeterminateAndKeepsStaging() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let relay = LeoSFTPRenameLossRelay(losing: .request)
        let access = LeoFileAccessor.sftp(launcher: relay)
        let path = sandbox.path("report.bin")

        await #expect(throws: LeoFileAccessError.indeterminate(path: path)) {
            try await access.create(Data("complete".utf8), at: path)
        }
        await access.close()

        let names = try sandbox.names()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(names.count == 1)
        #expect(names.allSatisfy { $0.wholeMatch(of: /\.report\.bin\.leo-[0-9a-f]{32}\.tmp/) != nil }, "the uncertain staging is retained")
        #expect(relay.renames == 1)
        #expect(relay.removesAfterRename == 0)
        #expect(relay.launches == 1, "never reconnects to retry")
    }
}
