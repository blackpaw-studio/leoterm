import CryptoKit
import Darwin
import Foundation

enum LeoPathKind: Equatable, Sendable {
    case absent
    case file
    case directory
    case symlink(target: String)
}

/// The file operations the managed install performs, as a seam: tests drive
/// an in-memory fake that records an ordered op log, so nothing under a real
/// `~/.leo` or `~/.local/bin` is ever touched.
protocol LeoFileSystem: Sendable {
    /// Never follows symlinks.
    func kind(at url: URL) -> LeoPathKind
    /// Permission bits (`0o600`), nil when absent. Never follows symlinks.
    func mode(at url: URL) -> mode_t?
    func read(_ url: URL) throws -> Data
    /// Temp file in the destination's directory, fsync, then `rename(2)`.
    func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws
    /// Creates missing parents (0755) and the leaf with `mode`; an existing directory is left alone.
    func createDirectory(at url: URL, mode: mode_t) throws
    func symlink(at url: URL, to target: String) throws
    /// Temp symlink in the same directory, then `rename(2)` over `url`.
    func replaceSymlinkAtomically(at url: URL, to target: String) throws
    /// `destination` must not exist.
    func copyFile(from source: URL, to destination: URL) throws
    /// `chmod(2)` on a regular file.
    func setMode(_ mode: mode_t, at url: URL) throws
    /// `rename(2)`: replaces `destination` if present.
    func move(from source: URL, to destination: URL) throws
    /// Like `move`, but fails with `EEXIST` instead of replacing `destination`
    /// (`renamex_np` + `RENAME_EXCL`): the only safe way to back a file up.
    func moveWithoutReplacing(from source: URL, to destination: URL) throws
    /// Unlinks a file or symlink; never recurses.
    func remove(_ url: URL) throws
    func trash(_ url: URL) throws
    func isWritable(_ url: URL) -> Bool
    func sha256(of url: URL) throws -> String
}

extension LeoFileSystem {
    /// Name of the sibling temp file used by the atomic operations.
    static func temporaryURL(for url: URL, token: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(token).tmp")
    }
}

struct LeoFileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
    let operation: String
    let path: String
    let code: Int32

    var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
}

struct LeoDiskFileSystem: LeoFileSystem {
    private let makeToken: @Sendable () -> String

    init(makeToken: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.makeToken = makeToken
    }

    func kind(at url: URL) -> LeoPathKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .symlink(target: target)
        case S_IFDIR:
            return .directory
        default:
            return .file
        }
    }

    func mode(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        let temporary = Self.temporaryURL(for: url, token: makeToken())
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw LeoFileSystemError(operation: "open", path: temporary.path, code: errno) }
        do {
            // The process umask may have narrowed `mode`; the marker needs exactly what was asked.
            try check(fchmod(descriptor, mode), "chmod", temporary)
            try writeAll(data, to: descriptor, at: temporary)
            try check(fsync(descriptor), "fsync", temporary)
            try check(close(descriptor), "close", temporary)
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        try rename(temporary, to: url)
    }

    func createDirectory(at url: URL, mode: mode_t) throws {
        switch kind(at: url) {
        case .directory:
            return
        case .absent:
            let parent = url.deletingLastPathComponent()
            if parent.path != url.path { try createDirectory(at: parent, mode: 0o755) }
            try check(mkdir(url.path, mode), "mkdir", url)
            try check(chmod(url.path, mode), "chmod", url)
        case .file, .symlink:
            throw LeoFileSystemError(operation: "mkdir", path: url.path, code: EEXIST)
        }
    }

    func symlink(at url: URL, to target: String) throws {
        try check(Darwin.symlink(target, url.path), "symlink", url)
    }

    func replaceSymlinkAtomically(at url: URL, to target: String) throws {
        let temporary = Self.temporaryURL(for: url, token: makeToken())
        try symlink(at: temporary, to: target)
        do {
            try rename(temporary, to: url)
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    func copyFile(from source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func setMode(_ mode: mode_t, at url: URL) throws {
        try check(chmod(url.path, mode), "chmod", url)
    }

    func move(from source: URL, to destination: URL) throws {
        try rename(source, to: destination)
    }

    func moveWithoutReplacing(from source: URL, to destination: URL) throws {
        try check(renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)), "rename", destination)
    }

    func remove(_ url: URL) throws {
        try check(unlink(url.path), "unlink", url)
    }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func isWritable(_ url: URL) -> Bool {
        access(url.path, W_OK) == 0
    }

    func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rename(_ source: URL, to destination: URL) throws {
        try check(Darwin.rename(source.path, destination.path), "rename", destination)
    }

    private func check(_ result: Int32, _ operation: String, _ url: URL) throws {
        guard result == 0 else { throw LeoFileSystemError(operation: operation, path: url.path, code: errno) }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, at url: URL) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw LeoFileSystemError(operation: "write", path: url.path, code: errno)
                }
                offset += written
            }
        }
    }
}
