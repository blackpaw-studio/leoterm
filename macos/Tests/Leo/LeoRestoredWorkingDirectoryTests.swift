import Foundation
import Testing

@testable import Ghostty

/// B-332: a restored terminal's shell starts where it was at quit, or at
/// home when that directory is gone.
struct LeoRestoredWorkingDirectoryTests {
    private static let home = "/Users/restored-home"

    @Test func anExistingDirectoryIsKept() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(LeoRestoredWorkingDirectory.resolve(pwd: directory, home: Self.home) == directory)
    }

    @Test func aMissingDirectoryGivesHome() throws {
        let directory = try Self.makeDirectory()
        try FileManager.default.removeItem(atPath: directory)

        #expect(LeoRestoredWorkingDirectory.resolve(pwd: directory, home: Self.home) == Self.home)
    }

    @Test func aFileGivesHome() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = (directory as NSString).appendingPathComponent("file")
        try Data().write(to: URL(fileURLWithPath: file))

        #expect(LeoRestoredWorkingDirectory.resolve(pwd: file, home: Self.home) == Self.home)
    }

    /// A shell that never reported where it was starts where a new one
    /// does: Ghostty's `working-directory`.
    @Test(arguments: [nil, ""] as [String?])
    func noDirectoryStaysNone(_ pwd: String?) {
        #expect(LeoRestoredWorkingDirectory.resolve(pwd: pwd, home: Self.home) == nil)
    }

    private static func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-restored-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.path
    }
}
