import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `LeoReservedTestDirectory` backs the socket directory tests share: it
/// must never adopt a directory another process already has, and must
/// only ever remove the one it created itself.
struct LeoReservedTestDirectoryTests {
    /// With every candidate name already taken (a one-`X` template has 62),
    /// reserving fails rather than reuse one, and cleanup removes none.
    @Test func anExistingDirectoryAtTheCandidateNameIsNeverReusedOrRemoved() throws {
        let parent = try Self.makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let candidates = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            .map { parent.appendingPathComponent("d-\($0)") }
        // A case-insensitive volume folds `d-A` onto `d-a`: already taken.
        for candidate in candidates where mkdir(candidate.path, 0o700) != 0 {
            #expect(errno == EEXIST, "\(candidate.path): errno \(errno)")
        }
        let reservation = LeoReservedTestDirectory(template: parent.appendingPathComponent("d-X").path)

        #expect(throws: (any Error).self) { try reservation.reserve() }
        reservation.removeIfReserved()

        #expect(candidates.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func cleanupDoesNothingWhenNothingWasReserved() throws {
        let parent = try Self.makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let other = parent.appendingPathComponent("d-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let reservation = LeoReservedTestDirectory(template: parent.appendingPathComponent("d-XXXXXXXX").path)

        reservation.removeIfReserved()

        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["d-other"])
    }

    /// Reserves once, owner-only, and removes exactly what it reserved.
    @Test func removesOnlyTheDirectoryItReserved() throws {
        let parent = try Self.makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let other = parent.appendingPathComponent("d-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let reservation = LeoReservedTestDirectory(template: parent.appendingPathComponent("d-XXXXXXXX").path)

        let directory = try reservation.reserve()
        #expect(try reservation.reserve() == directory)
        var info = Darwin.stat()
        #expect(stat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        reservation.removeIfReserved()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["d-other"])
    }

    private static func makeParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("lrtd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }
}
