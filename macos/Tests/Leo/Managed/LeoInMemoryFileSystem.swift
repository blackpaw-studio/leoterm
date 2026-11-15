import CryptoKit
import Foundation

@testable import Ghostty

enum LeoFileOp: Equatable, Sendable {
    case createDirectory(String, mode: mode_t)
    case write(String, mode: mode_t)
    case rename(String, String)
    case remove(String)
    case symlink(String, target: String)
    case copy(String, String)
    case chmod(String, mode: mode_t)
    case move(String, String)
    case moveNoReplace(String, String)
    case trash(String)
}

/// In-memory `LeoFileSystem` with an ordered op log. Atomic operations log
/// their temp-file step and the `rename`, like the real implementation does.
/// Tokens are sequential (`t1`, `t2`, …) so temp names are assertable.
final class LeoInMemoryFileSystem: LeoFileSystem, @unchecked Sendable {
    private enum Node {
        case file(Data, mode: mode_t)
        case directory(mode: mode_t)
        case symlink(String)
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var tokenCounter = 0
    private var readOnlyPrefixes: [String] = []
    private var failures: [String: LeoFileSystemError] = [:]
    private var observer: (@Sendable (LeoFileOp) -> Void)?
    private var corruptsNextCopy = false
    private var log: [LeoFileOp] = [] {
        didSet { if let op = log.last, log.count > oldValue.count { observer?(op) } }
    }

    var ops: [LeoFileOp] { locked { log } }

    /// Also reports each op to `observer`, so a test can interleave file ops
    /// with other seams' calls in one timeline.
    func observe(_ observer: @escaping @Sendable (LeoFileOp) -> Void) { locked { self.observer = observer } }

    /// The next `copyFile` writes different bytes than it read.
    func corruptNextCopy() { locked { corruptsNextCopy = true } }

    // MARK: arranging

    func addFile(_ path: String, _ contents: String = "", mode: mode_t = 0o644) {
        addFile(path, Data(contents.utf8), mode: mode)
    }

    func addFile(_ path: String, _ contents: Data, mode: mode_t = 0o644) {
        locked {
            makeParents(of: path)
            nodes[path] = .file(contents, mode: mode)
        }
    }

    func addDirectory(_ path: String, mode: mode_t = 0o755) {
        locked {
            makeParents(of: path)
            nodes[path] = .directory(mode: mode)
        }
    }

    func addSymlink(_ path: String, to target: String) {
        locked {
            makeParents(of: path)
            nodes[path] = .symlink(target)
        }
    }

    func markReadOnly(_ prefix: String) { locked { readOnlyPrefixes.append(prefix) } }

    /// Makes the next operation named `operation` on `path` throw (once).
    func failNext(_ operation: String, at path: String, code: Int32 = EIO) {
        locked { failures["\(operation) \(path)"] = LeoFileSystemError(operation: operation, path: path, code: code) }
    }

    func clearLog() { locked { log.removeAll() } }

    func contents(of path: String) -> String? {
        locked {
            guard case let .file(data, _) = nodes[path] else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: LeoFileSystem

    func kind(at url: URL) -> LeoPathKind {
        locked {
            switch nodes[url.path] {
            case nil: .absent
            case .file: .file
            case .directory: .directory
            case let .symlink(target): .symlink(target: target)
            }
        }
    }

    func mode(at url: URL) -> mode_t? {
        locked {
            switch nodes[url.path] {
            case let .file(_, mode), let .directory(mode): mode
            case .symlink: 0o755
            case nil: nil
            }
        }
    }

    func read(_ url: URL) throws -> Data {
        try locked {
            try fail("read", url.path)
            guard case let .file(data, _) = nodes[url.path] else { throw LeoFileSystemError(operation: "read", path: url.path, code: ENOENT) }
            return data
        }
    }

    func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        try locked {
            let temporary = nextTemporary(for: url)
            try fail("write", url.path)
            log.append(.write(temporary.path, mode: mode))
            nodes[temporary.path] = .file(data, mode: mode)
            try renameLocked(temporary.path, url.path)
        }
    }

    func createDirectory(at url: URL, mode: mode_t) throws {
        try locked {
            try fail("createDirectory", url.path)
            log.append(.createDirectory(url.path, mode: mode))
            makeParents(of: url.path)
            nodes[url.path] = .directory(mode: mode)
        }
    }

    func symlink(at url: URL, to target: String) throws {
        try locked {
            try fail("symlink", url.path)
            guard nodes[url.path] == nil else { throw LeoFileSystemError(operation: "symlink", path: url.path, code: EEXIST) }
            log.append(.symlink(url.path, target: target))
            nodes[url.path] = .symlink(target)
        }
    }

    func replaceSymlinkAtomically(at url: URL, to target: String) throws {
        try locked {
            let temporary = nextTemporary(for: url)
            try fail("replaceSymlink", url.path)
            log.append(.symlink(temporary.path, target: target))
            nodes[temporary.path] = .symlink(target)
            try renameLocked(temporary.path, url.path)
        }
    }

    func copyFile(from source: URL, to destination: URL) throws {
        try locked {
            try fail("copy", destination.path)
            guard case .file = nodes[source.path] else { throw LeoFileSystemError(operation: "copy", path: source.path, code: ENOENT) }
            guard nodes[destination.path] == nil else { throw LeoFileSystemError(operation: "copy", path: destination.path, code: EEXIST) }
            log.append(.copy(source.path, destination.path))
            nodes[destination.path] = nodes[source.path]
            if corruptsNextCopy, case let .file(data, mode) = nodes[source.path] {
                corruptsNextCopy = false
                nodes[destination.path] = .file(data + Data("!".utf8), mode: mode)
            }
        }
    }

    func setMode(_ mode: mode_t, at url: URL) throws {
        try locked {
            try fail("chmod", url.path)
            guard case let .file(data, _) = nodes[url.path] else { throw LeoFileSystemError(operation: "chmod", path: url.path, code: ENOENT) }
            log.append(.chmod(url.path, mode: mode))
            nodes[url.path] = .file(data, mode: mode)
        }
    }

    func move(from source: URL, to destination: URL) throws {
        try locked {
            try fail("move", destination.path)
            log.append(.move(source.path, destination.path))
            guard let node = nodes.removeValue(forKey: source.path) else {
                throw LeoFileSystemError(operation: "move", path: source.path, code: ENOENT)
            }
            nodes[destination.path] = node
        }
    }

    func moveWithoutReplacing(from source: URL, to destination: URL) throws {
        try locked {
            try fail("moveNoReplace", destination.path)
            guard nodes[destination.path] == nil else {
                throw LeoFileSystemError(operation: "rename", path: destination.path, code: EEXIST)
            }
            log.append(.moveNoReplace(source.path, destination.path))
            guard let node = nodes.removeValue(forKey: source.path) else {
                throw LeoFileSystemError(operation: "rename", path: source.path, code: ENOENT)
            }
            nodes[destination.path] = node
        }
    }

    func remove(_ url: URL) throws {
        try locked {
            try fail("remove", url.path)
            log.append(.remove(url.path))
            guard nodes.removeValue(forKey: url.path) != nil else {
                throw LeoFileSystemError(operation: "remove", path: url.path, code: ENOENT)
            }
        }
    }

    func trash(_ url: URL) throws {
        try locked {
            try fail("trash", url.path)
            log.append(.trash(url.path))
            guard nodes.removeValue(forKey: url.path) != nil else {
                throw LeoFileSystemError(operation: "trash", path: url.path, code: ENOENT)
            }
        }
    }

    func isWritable(_ url: URL) -> Bool {
        locked { !readOnlyPrefixes.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } }
    }

    func sha256(of url: URL) throws -> String {
        let data = try read(url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: internals (lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func nextTemporary(for url: URL) -> URL {
        tokenCounter += 1
        return Self.temporaryURL(for: url, token: "t\(tokenCounter)")
    }

    private func renameLocked(_ source: String, _ destination: String) throws {
        log.append(.rename(source, destination))
        guard let node = nodes.removeValue(forKey: source) else {
            throw LeoFileSystemError(operation: "rename", path: source, code: ENOENT)
        }
        nodes[destination] = node
    }

    private func makeParents(of path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        while parent != "/", !parent.isEmpty, nodes[parent] == nil {
            nodes[parent] = .directory(mode: 0o755)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    private func fail(_ operation: String, _ path: String) throws {
        if let error = failures.removeValue(forKey: "\(operation) \(path)") { throw error }
    }
}
