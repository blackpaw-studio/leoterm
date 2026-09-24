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
///
/// It also fails the run if tests added test-suite-named plists to the real
/// `~/Library/Preferences` -- tests inject `LeoInMemoryDefaults` instead of
/// a `UserDefaults(suiteName:)` suite (B-039).
@objc(LeoRealCacheDirectoryGuard)
final class LeoRealCacheDirectoryGuard: NSObject, XCTestObservation {
    private let directories = [LeoControlSocketDirectory.default, LeoTunnelOrphanStore.defaultLegacySocketDirectory].compactMap(\.self)
    private var before: Set<String> = []
    private var preferencesBefore: Result<Set<String>, any Error> = .success([])
    private static let listedPreferencesLimit = 20

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_: Bundle) {
        before = LeoRealDirectoryListing.paths(in: directories)
        preferencesBefore = Result { try LeoTestPreferencesListing.names() }
    }

    func testBundleDidFinish(_: Bundle) {
        // Only the directory this process reserved, if it reserved one.
        LeoHostSelectionTestSupport.socketDirectoryReservation.removeIfReserved()
        let added = LeoRealDirectoryListing.paths(in: directories).subtracting(before)
        let addedPreferences = Result { try LeoTestPreferencesListing.names() }
            .flatMap { after in preferencesBefore.map { after.subtracting($0) } }
        let failures = [socketFailure(added), preferencesFailure(addedPreferences)].compactMap(\.self)
        guard !failures.isEmpty else { return }
        FileHandle.standardError.write(Data(failures.joined().utf8))
        exit(EXIT_FAILURE)
    }

    private func socketFailure(_ added: Set<String>) -> String? {
        guard !added.isEmpty else { return nil }
        return """
        ✘ Test realSocketDirectoriesAreUnchanged() failed: the test run added \(added.count) \
        entr\(added.count == 1 ? "y" : "ies") to the real socket directories -- inject a temp \
        directory instead (or, if the debug app connected to a remote host during the run, rerun):
        \(added.sorted().map { "  \($0)" }.joined(separator: "\n"))

        """
    }

    private func preferencesFailure(_ result: Result<Set<String>, any Error>) -> String? {
        let added: Set<String>
        switch result {
        case let .success(names): added = names
        case let .failure(error):
            return """
            ✘ Test realPreferencesAreUnchanged() failed: couldn't list \(LeoTestPreferencesListing.directory.path) \
            to check for leaked test-suite plists: \(error)

            """
        }
        guard !added.isEmpty else { return nil }
        return """
        ✘ Test realPreferencesAreUnchanged() failed: the test run added \(added.count) \
        test-suite plist\(added.count == 1 ? "" : "s") to \(LeoTestPreferencesListing.directory.path) \
        -- inject LeoInMemoryDefaults instead of UserDefaults(suiteName:):
        \(added.sorted().prefix(Self.listedPreferencesLimit).map { "  \($0)" }.joined(separator: "\n"))
        \(added.count > Self.listedPreferencesLimit ? "  … and \(added.count - Self.listedPreferencesLimit) more\n" : "")

        """
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
