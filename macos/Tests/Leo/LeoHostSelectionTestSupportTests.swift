import Foundation
import Testing

@testable import Ghostty

/// The directory `LeoHostSelectionTestSupport` shares between tests must
/// belong to one test process: a fixed path is shared by every run and
/// every parallel worker, so a later run meets a stale socket and one
/// worker's `LeoTunnel.removeStaleSocket()` can unlink another's live one.
struct LeoHostSelectionTestSupportTests {
    @Test func theSharedSocketDirectoryBelongsToThisProcessOnly() {
        let name = LeoHostSelectionTestSupport.localSocketDirectory.lastPathComponent

        #expect(name != "leoterm-tests-hosts", "a fixed name is shared by every run and worker")
        #expect(name.hasPrefix("leoterm-tests-") && name.count == "leoterm-tests-".count + 8)
    }

    /// Still short enough for ssh's control-path budget (and so the
    /// shorter AF_UNIX one for the forwarded socket).
    @Test func theSharedSocketDirectoryLeavesRoomForTheControlSocket() {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work")

        #expect(LeoSSHCommand.isValidControlPath(LeoHostSelectionTestSupport.expectedControlPath(configuration)))
    }
}
