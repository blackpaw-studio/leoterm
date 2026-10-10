import Foundation
import Testing

@testable import Ghostty

/// A download that loses its connection or access part way (B-279) fails
/// plainly and leaves nothing in the drop folder -- never a partial file.
struct LeoSFTPDownloadLossTests {
    @Test func aConnectionLostMidDownloadFailsPlainlyLeavingNoPartialFile() async throws {
        let drop = try LeoFileSandbox()
        defer { drop.cleanUp() }
        let launcher = LeoFakeSFTPLauncher(fileSize: 40, extraBytesPerRead: 0, dropAfterReads: 2)
        let access = LeoFileAccessor.sftp(launcher: launcher, options: .init(chunkSize: 4, maxRequestsInFlight: 1))
        let pushed = LeoRecordingByteSink()

        let error = await #expect(throws: LeoFileAccessError.disconnected) {
            try await LeoFileExport.download(remotePath: "/f.bin", to: URL(fileURLWithPath: drop.path("f.bin")), access: access) { offset in
                try await pushed.write(Data(count: 4), at: offset)
            }
        }
        await access.close()

        #expect(pushed.pushes.count == 2, "the cut came mid-file, after two chunks were written")
        #expect(error.map(LeoFileExport.message(for:)) == "The connection to the host was lost.")
        #expect(try drop.names().isEmpty)
    }

    @Test(arguments: LeoFileExportTests.kinds)
    func closingTheAccessMidDownloadLeavesNoPartialFile(_ kind: LeoFileBackendKind) async throws {
        let drop = try LeoFileSandbox()
        defer { drop.cleanUp() }
        try await withLeoFileSandbox(kind) { workspace, access in
            try leoPatternData(count: 3 * kind.readWindowSize).write(to: URL(fileURLWithPath: workspace.path("a.bin")))

            await #expect(throws: LeoFileAccessError.closed) {
                try await LeoFileExport.download(remotePath: workspace.path("a.bin"), to: URL(fileURLWithPath: drop.path("a.bin")), access: access) { _ in
                    await access.close()
                }
            }
            #expect(try drop.names().isEmpty)
        }
    }
}
