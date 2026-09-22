import Foundation
import Testing

@testable import Ghostty

/// Every backend the shared contract suite runs against. A contract test
/// takes one of these as its argument, so each behaviour is asserted
/// identically for local and remote.
enum LeoFileBackendKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case local

    var testDescription: String { rawValue }

    func makeAccess() -> any LeoFileAccess {
        switch self {
        case .local: LeoFileAccessor.local()
        }
    }
}

/// A throwaway directory for one test. `cleanUp()` restores permissions a
/// test may have removed before deleting it.
struct LeoFileSandbox {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("leo-files-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path
    }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    @discardableResult
    func file(_ relative: String, _ contents: String, permissions: Int = 0o644) throws -> String {
        let full = path(relative)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: full))
        try chmod(relative, permissions)
        return full
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: destination)
        return full
    }

    func chmod(_ relative: String, _ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path(relative))
    }

    func contents(_ relative: String) throws -> String {
        try String(contentsOfFile: path(relative), encoding: .utf8)
    }

    func permissions(_ relative: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path(relative))[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func inode(_ relative: String) throws -> UInt64 {
        try (FileManager.default.attributesOfItem(atPath: path(relative))[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func names(in relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? root : path(relative)).sorted()
    }

    func cleanUp() {
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(relative))
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Runs `body` against a fresh sandbox and a fresh accessor of `kind`,
/// always cleaning both up.
func withLeoFileSandbox(
    _ kind: LeoFileBackendKind,
    _ body: (LeoFileSandbox, any LeoFileAccess) async throws -> Void
) async throws {
    let sandbox = try LeoFileSandbox()
    let access = kind.makeAccess()
    defer { sandbox.cleanUp() }
    do {
        try await body(sandbox, access)
    } catch {
        await access.close()
        throw error
    }
    await access.close()
}

/// Deterministic pseudo-random bytes (a large file must not compress into
/// something a chunking bug could still reproduce by accident).
func leoPatternData(count: Int) -> Data {
    var state: UInt32 = 0x2545_F491
    return Data((0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return UInt8(truncatingIfNeeded: state)
    })
}
