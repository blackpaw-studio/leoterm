import Foundation

/// The raw filesystem operations `LeoFileAccessor` composes. A backend maps
/// its native failures to `LeoFileAccessError` and does nothing else:
/// validation, kind checks, conflict checks, symlink handling and ordering
/// all live in `LeoFileAccessor`, so local and remote cannot drift apart.
protocol LeoFileAccessBackend: Sendable {
    /// Follows symlinks.
    func stat(_ path: String) async throws -> LeoFileStat
    /// Describes a symlink itself.
    func lstat(_ path: String) async throws -> LeoFileStat
    /// Canonical absolute path with every symlink resolved. `path` exists.
    func realpath(_ path: String) async throws -> String
    /// The user's home directory, absolute.
    func homeDirectory() async throws -> String
    /// Unordered; may include `.` and `..`; entries described via `lstat`.
    func entries(of directory: String) async throws -> [LeoFileEntry]
    /// The file's bytes, stopping once more than `limit` have been read.
    func contents(of path: String, limit: UInt64) async throws -> Data
    /// Creates `path` exclusively (failing if it exists), writes `source`
    /// (pulled one bounded chunk at a time), and sets exactly `permissions`
    /// when non-nil (otherwise the host's default for a new file). After an exclusive OPEN succeeds, an ordinary write
    /// failure removes this uploader-owned private path. A disconnect may
    /// retain it because the server's last completed operation is uncertain.
    func create(_ path: String, from source: any LeoFileByteSource, permissions: UInt16?) async throws
    /// Atomically moves a fully written `source` into an absent
    /// `destination`, failing rather than replacing anything there.
    func publishExclusive(_ destination: String, with source: String) async throws
    func remove(_ path: String) async throws
    /// Moves `source` over `destination`, replacing it. On failure, removes
    /// `source` unless that could lose the only copy of the data.
    func replace(_ destination: String, with source: String) async throws
    /// Releases any connection. Final: a later call fails as `.closed`.
    func close() async
}

extension LeoFileAccessBackend {
    func close() async {}

    func publishExclusive(_ destination: String, with source: String) async throws {
        throw LeoFileAccessError.unavailable(reason: "This file connection doesn’t support exclusive publication")
    }
}

/// `LeoFileAccess` over any `LeoFileAccessBackend`: the single place the
/// contract's semantics are implemented.
struct LeoFileAccessor<Backend: LeoFileAccessBackend>: LeoFileAccess {
    let backend: Backend
    /// Set by `close()`, after which every call fails as `.closed` -- for
    /// every backend alike.
    private let closed = LeoFileAccessClosedFlag()

    init(backend: Backend) {
        self.backend = backend
    }

    func list(_ path: String) async throws -> [LeoFileEntry] {
        try closed.check()
        try Self.validate(path)
        guard try await backend.stat(path).kind == .directory else { throw LeoFileAccessError.notADirectory(path: path) }
        return try await backend.entries(of: path)
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { $0.name < $1.name }
    }

    func stat(_ path: String) async throws -> LeoFileStat {
        try closed.check()
        try Self.validate(path)
        return try await backend.stat(path)
    }

    /// A server's answer is untrusted: anything but an absolute path is a
    /// protocol error rather than a base for relative paths.
    func homeDirectory() async throws -> String {
        try closed.check()
        let home = try await backend.homeDirectory()
        guard home.hasPrefix("/"), !home.contains("\0") else {
            throw LeoFileAccessError.protocolError("the home directory isn’t an absolute path")
        }
        return home
    }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        try closed.check()
        try Self.validate(path)
        let stat = try await backend.stat(path)
        try Self.requireRegularFile(stat, path: path)
        guard stat.size <= maxBytes else { throw LeoFileAccessError.tooLarge(path: path, size: stat.size, limit: maxBytes) }
        let data = try await backend.contents(of: path, limit: maxBytes)
        guard UInt64(data.count) <= maxBytes else {
            throw LeoFileAccessError.tooLarge(path: path, size: UInt64(data.count), limit: maxBytes)
        }
        return LeoFileContents(data: data, stat: stat)
    }

    /// Checks the version twice: up front, so a stale save fails before any
    /// bytes move, and again after the temp file is written, just before the
    /// rename, to shrink the race window to the rename itself (an unavoidable
    /// TOCTOU gap -- neither rename(2) nor SFTP offers compare-and-swap).
    /// The returned stat is the temp file's, taken before the rename (which
    /// keeps size and mtime), so a completed save is never reported failed.
    @discardableResult
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try closed.check()
        try Self.validate(path)
        let target = try await writeTarget(for: path)
        let existing = try await statIfPresent(target)
        if let existing { try Self.requireRegularFile(existing, path: path) }
        try Self.check(expected, against: existing, path: path)

        let temporary = Self.temporarySibling(of: target)
        do {
            try await backend.create(temporary, from: data, permissions: existing?.permissions)
        } catch {
            throw LeoFileAccessError.wrapping(error, path: temporary).retargeted(to: path)
        }
        let written: LeoFileStat
        do {
            written = try await backend.stat(temporary)
            try Self.check(expected, against: try await statIfPresent(target), path: path)
        } catch {
            try? await backend.remove(temporary)
            throw LeoFileAccessError.wrapping(error, path: temporary).retargeted(to: path)
        }
        do {
            try await backend.replace(target, with: temporary)
        } catch {
            throw LeoFileAccessError.wrapping(error, path: target).retargeted(to: path)
        }
        return written
    }

    /// A complete hidden sibling is atomically published with no-replace
    /// semantics. The destination therefore never contains partial bytes,
    /// including when an SFTP connection disappears during a chunked write.
    /// Failure cleanup never names the destination: an attacker replacing a
    /// path after publication cannot have that replacement unlinked here.
    @discardableResult
    func create(at path: String, from source: any LeoFileByteSource) async throws -> LeoFileStat {
        try closed.check()
        try Self.validate(path)
        if try await statIfPresent(path, followingLinks: false) != nil {
            throw LeoFileAccessError.conflict(path: path)
        }
        let staged = Self.temporarySibling(of: path)
        do {
            // D-355: staging bytes stay private until exclusive publication.
            try await backend.create(staged, from: source, permissions: 0o600)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LeoFileAccessError.wrapping(error, path: staged).retargeted(to: path)
        }
        let result: LeoFileStat
        do {
            result = try await backend.stat(staged)
            try Self.requireRegularFile(result, path: path)
        } catch {
            if !Self.isUncertain(error) { try? await backend.remove(staged) }
            throw LeoFileAccessError.wrapping(error, path: staged).retargeted(to: path)
        }
        do {
            try Task.checkCancellation()
            try await backend.publishExclusive(path, with: staged)
        } catch is CancellationError {
            try? await backend.remove(staged)
            throw CancellationError()
        } catch {
            if Self.isUncertain(error) {
                // The RENAME request may have committed before its reply was
                // lost. Never retry or remove either pathname blindly.
                throw LeoFileAccessError.indeterminate(path: path)
            }
            try? await backend.remove(staged)
            if (try? await backend.lstat(path)) != nil { throw LeoFileAccessError.conflict(path: path) }
            throw LeoFileAccessError.wrapping(error, path: path)
        }
        return result
    }

    func close() async {
        closed.set()
        await backend.close()
    }

    // MARK: - Helpers

    /// A symlink is written through (its target is replaced, the link kept)
    /// -- agent workspaces routinely symlink e.g. `CLAUDE.md` -> `AGENTS.md`.
    /// A dangling link is `.notFound` rather than silently creating its target.
    private func writeTarget(for path: String) async throws -> String {
        guard let link = try await statIfPresent(path, followingLinks: false), link.kind == .symlink else { return path }
        do {
            _ = try await backend.stat(path)
            return try await backend.realpath(path)
        } catch let error as LeoFileAccessError {
            throw error.retargeted(to: path)
        }
    }

    private func statIfPresent(_ path: String, followingLinks: Bool = true) async throws -> LeoFileStat? {
        do {
            return followingLinks ? try await backend.stat(path) : try await backend.lstat(path)
        } catch LeoFileAccessError.notFound {
            return nil
        }
    }

    /// Directories get their own error; FIFOs, sockets and devices are
    /// never opened (a FIFO blocks the opener until a writer appears).
    private static func requireRegularFile(_ stat: LeoFileStat, path: String) throws {
        switch stat.kind {
        case .file: return
        case .directory: throw LeoFileAccessError.isADirectory(path: path)
        case .symlink, .other: throw LeoFileAccessError.failed(path: path, reason: "it isn’t a regular file")
        }
    }

    private static func check(_ expected: LeoFileVersion?, against current: LeoFileStat?, path: String) throws {
        guard let expected, current?.version != expected else { return }
        throw LeoFileAccessError.conflict(path: path)
    }

    private static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw LeoFileAccessError.invalidPath(path) }
    }

    private static func isUncertain(_ error: Error) -> Bool {
        switch error as? LeoFileAccessError {
        case .disconnected, .closed: true
        default: false
        }
    }

    /// `.<name>.leo-<random>.tmp` beside the target, so the final rename
    /// never crosses a filesystem boundary. The name part is capped so the
    /// temp name stays within NAME_MAX (255 bytes) for any target name.
    static func temporarySibling(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // swiftlint:disable:next optional_data_string_conversion
        let stem = name.utf8.count <= temporaryStemLimit ? name : String(decoding: name.utf8.prefix(temporaryStemLimit), as: UTF8.self)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return (directory as NSString).appendingPathComponent(".\(stem).leo-\(token).tmp")
    }

    /// 255 - 42 bytes of `.` + `.leo-<32>.tmp`, less 3 in case truncating
    /// mid-character leaves a replacement character (3 bytes in UTF-8).
    private static var temporaryStemLimit: Int { 210 }
}

extension LeoFileAccessor where Backend == LeoLocalFileBackend {
    static func local() -> LeoFileAccessor<LeoLocalFileBackend> {
        LeoFileAccessor(backend: LeoLocalFileBackend())
    }
}

/// Whether a `LeoFileAccessor` (a value type, copied freely) was closed.
final class LeoFileAccessClosedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.withLock { isSet = true }
    }

    func check() throws {
        if lock.withLock({ isSet }) { throw LeoFileAccessError.closed }
    }
}
