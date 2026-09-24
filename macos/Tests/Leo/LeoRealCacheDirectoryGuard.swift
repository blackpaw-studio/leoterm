import Darwin
import Foundation
import XCTest

@testable import Ghostty

/// The test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass`):
/// XCTest creates it before any test runs. It lists the app's real socket
/// directories -- the per-user cache directory the tunnel and instance-lock
/// files live in, and the pre-B-021 `~/.leo/state/leoterm` -- when the
/// bundle starts, and fails the run if they gained entries by the time it
/// finishes. Tests must inject a temp directory instead (B-032).
///
/// `testBundleDidFinish` fires after the Swift Testing run as well as the
/// XCTest one, but no test is running by then to record an issue against,
/// so a leak is printed as a failed test and the host exits non-zero.
/// Only additions count: the running debug app shares the cache directory
/// and may remove its own sockets mid-run. It could also add one (by
/// connecting to a remote host during the run); the message names that.
@objc(LeoRealCacheDirectoryGuard)
final class LeoRealCacheDirectoryGuard: NSObject, XCTestObservation {
    private let directories = [LeoControlSocketDirectory.default, LeoTunnelOrphanStore.defaultLegacySocketDirectory].compactMap(\.self)
    private var before: Set<String> = []

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_: Bundle) {
        before = LeoRealDirectoryListing.paths(in: directories)
    }

    func testBundleDidFinish(_: Bundle) {
        // Only the directory this process reserved, if it reserved one.
        LeoHostSelectionTestSupport.socketDirectoryReservation.removeIfReserved()
        let added = LeoRealDirectoryListing.paths(in: directories).subtracting(before)
        guard !added.isEmpty else { return }
        let message = """
        ✘ Test realSocketDirectoriesAreUnchanged() failed: the test run added \(added.count) \
        entr\(added.count == 1 ? "y" : "ies") to the real socket directories -- inject a temp \
        directory instead (or, if the debug app connected to a remote host during the run, rerun):
        \(added.sorted().map { "  \($0)" }.joined(separator: "\n"))

        """
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}

enum LeoRealDirectoryListing {
    /// Full paths of `directories`' entries; a missing directory has none.
    static func paths(in directories: [URL]) -> Set<String> {
        Set(directories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { directory.appendingPathComponent($0).path }
        })
    }
}
