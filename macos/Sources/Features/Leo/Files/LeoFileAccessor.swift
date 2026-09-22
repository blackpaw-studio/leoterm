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
    /// Unordered; may include `.` and `..`; entries described via `lstat`.
    func entries(of directory: String) async throws -> [LeoFileEntry]
    /// The file's bytes, stopping once more than `limit` have been read.
    func contents(of path: String, limit: UInt64) async throws -> Data
    /// Creates `path` exclusively (failing if it exists), writes `data`, and
    /// sets exactly `permissions` when non-nil (otherwise the host's default
    /// for a new file). Removes the file again if anything after creation fails.
    func create(_ path: String, data: Data, permissions: UInt16?) async throws
    func remove(_ path: String) async throws
    /// Moves `source` over `destination`, replacing it. On failure, removes
    /// `source` unless that could lose the only copy of the data.
    func replace(_ destination: String, with source: String) async throws
    /// Releases any connection; a later call may open a new one.
    func close() async
}

extension LeoFileAccessBackend {
    func close() async {}
}

/// `LeoFileAccess` over any `LeoFileAccessBackend`: the single place the
/// contract's semantics are implemented.
struct LeoFileAccessor<Backend: LeoFileAccessBackend>: LeoFileAccess {
    let backend: Backend

    func list(_ path: String) async throws -> [LeoFileEntry] {
        try Self.validate(path)
        guard try await backend.stat(path).kind == .directory else { throw LeoFileAccessError.notADirectory(path: path) }
        return try await backend.entries(of: path)
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { $0.name < $1.name }
    }

    func stat(_ path: String) async throws -> LeoFileStat {
        try Self.validate(path)
        return try await backend.stat(path)
    }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        try Self.validate(path)
        let stat = try await backend.stat(path)
        guard stat.kind != .directory else { throw LeoFileAccessError.isADirectory(path: path) }
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
    @discardableResult
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try Self.validate(path)
        let target = try await writeTarget(for: path)
        let existing = try await statIfPresent(target)
        if existing?.kind == .directory { throw LeoFileAccessError.isADirectory(path: path) }
        try Self.check(expected, against: existing, path: path)

        let temporary = Self.temporarySibling(of: target)
        do {
            try await backend.create(temporary, data: data, permissions: existing?.permissions)
        } catch {
            throw LeoFileAccessError.wrapping(error, path: temporary).retargeted(to: path)
        }
        do {
            try Self.check(expected, against: try await statIfPresent(target), path: path)
        } catch {
            try? await backend.remove(temporary)
            throw error
        }
        do {
            try await backend.replace(target, with: temporary)
        } catch {
            throw LeoFileAccessError.wrapping(error, path: target).retargeted(to: path)
        }
        return try await backend.stat(target)
    }

    func close() async {
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

    private static func check(_ expected: LeoFileVersion?, against current: LeoFileStat?, path: String) throws {
        guard let expected, current?.version != expected else { return }
        throw LeoFileAccessError.conflict(path: path)
    }

    private static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw LeoFileAccessError.invalidPath(path) }
    }

    /// `.<name>.leo-<random>.tmp` beside the target, so the final rename
    /// never crosses a filesystem boundary.
    static func temporarySibling(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        return (directory as NSString).appendingPathComponent(".\(name).leo-\(token).tmp")
    }
}

extension LeoFileAccessor where Backend == LeoLocalFileBackend {
    static func local() -> LeoFileAccessor<LeoLocalFileBackend> {
        LeoFileAccessor(backend: LeoLocalFileBackend())
    }
}
