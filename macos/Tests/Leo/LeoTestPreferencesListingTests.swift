import Foundation
import Testing

@testable import Ghostty

struct LeoTestPreferencesListingTests {
    @Test(arguments: [
        "LeoSidebarTests.plist",
        "LeoSidebarSplitTests.plist",
        "LeoSidebarFeedRecoveryTests.picker.8A0F1E62-3C1B-4B0E-9D57-2B1C0C7A9F10.plist",
        "LeoHostSelectionTests.applied.plist",
        "GhosttyAttachContentHostFocusTests.x.plist",
    ])
    func matchesTestSuiteNames(_ name: String) {
        #expect(LeoTestPreferencesListing.isTestSuiteName(name))
    }

    @Test(arguments: [
        "studio.blackpaw.leo.macos.debug.plist",
        "studio.blackpaw.leo.macos.plist",
        "com.mitchellh.ghostty.debug.plist",
        "com.google.chrome.for.testing.plist",
        "LeoSidebarTests.plist.lockfile",
        "LeoTestsHelper.plist",
        // Another process's bare-UUID domain is not the tests' doing.
        "8A0F1E62-3C1B-4B0E-9D57-2B1C0C7A9F10.plist",
    ])
    func ignoresOtherPlists(_ name: String) {
        #expect(!LeoTestPreferencesListing.isTestSuiteName(name))
    }

    @Test func listsOnlyTestSuiteNamedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["LeoSidebarTests.a.plist", "studio.blackpaw.leo.macos.debug.plist"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }

        #expect(try LeoTestPreferencesListing.names(in: directory) == ["LeoSidebarTests.a.plist"])
    }

    /// An unreadable directory must fail the guard, never pass as empty.
    @Test func anUnreadableDirectoryThrowsInsteadOfListingNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(throws: (any Error).self) { try LeoTestPreferencesListing.names(in: missing) }
    }
}
