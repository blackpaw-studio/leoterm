import Foundation

/// Reads and writes files on the selected host: the local filesystem for
/// localhost, SFTP over the app's SSH ControlMaster for a remote host. Both
/// backends share `LeoFileAccessor`'s semantics, so callers (the editor pane,
/// the workspace browser) see identical behaviour and identical errors either
/// way. Every path must be absolute; every error is a `LeoFileAccessError`.
protocol LeoFileAccess: Sendable {
    /// The directory's entries (never `.`/`..`), sorted by name. Entries are
    /// described without following symlinks; `path` itself may be a symlink
    /// to a directory.
    func list(_ path: String) async throws -> [LeoFileEntry]

    /// Follows symlinks.
    func stat(_ path: String) async throws -> LeoFileStat

    /// The host user's home directory (what `~` means in a surfaced path).
    func homeDirectory() async throws -> String

    /// The file's bytes plus the `stat` taken *before* reading, so
    /// `contents.stat.version` is safe to pass back to `write` as the
    /// conflict token (a change racing the read makes a save report a
    /// conflict rather than silently clobbering it).
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents

    /// Atomically replaces `path` (temp file in the same directory, then
    /// rename over it), keeping the existing file's permission bits. Writing
    /// through a symlink replaces the link's target, not the link. With a
    /// non-nil `expected`, fails with `.conflict` unless the file still has
    /// exactly that version. Returns the stat of the written file.
    ///
    /// Because the file is replaced rather than rewritten in place, the
    /// saved file is a new inode: saving needs write permission on the
    /// containing directory (a writable file in a read-only directory fails
    /// with `.permissionDenied`), and only the permission bits carry over --
    /// the original's owner and group (it is now owned by whoever saved it),
    /// ACLs, extended attributes and hard links (other links keep the old
    /// contents) are lost.
    @discardableResult
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat

    /// Creates a new regular file without ever replacing an existing path.
    /// A collision is `.conflict`; a failed create leaves no destination.
    @discardableResult
    func create(_ data: Data, at path: String) async throws -> LeoFileStat

    /// Releases any connection the accessor holds (the SFTP session) at
    /// once, without waiting for what's in flight, which fails. Final: every
    /// later call fails with `.closed` and nothing reconnects. Safe to call
    /// more than once.
    func close() async
}

extension LeoFileAccess {
    /// Test doubles and specialized read-only accessors remain source
    /// compatible. Production local and SFTP access use
    /// `LeoFileAccessor`'s exclusive implementation below.
    func create(_ data: Data, at path: String) async throws -> LeoFileStat {
        throw LeoFileAccessError.unavailable(reason: "This file connection doesn’t support creating files")
    }
}

enum LeoFileKind: Equatable, Sendable {
    case file
    case directory
    case symlink
    /// Sockets, FIFOs, devices -- listed, never opened.
    case other

    /// Maps the `S_IFMT` bits of a POSIX `st_mode`.
    init(mode: UInt32) {
        switch mode & 0o170000 {
        case 0o100000: self = .file
        case 0o040000: self = .directory
        case 0o120000: self = .symlink
        default: self = .other
        }
    }
}

/// Opaque "has this file changed since I read it" token. Equality is exact;
/// each backend fills `modified` at its native precision (nanoseconds
/// locally, whole seconds over SFTP v3), which is why `size` rides along --
/// a same-second rewrite over SFTP is still caught when the length changed.
struct LeoFileVersion: Hashable, Sendable {
    let modified: Date
    let size: UInt64
}

struct LeoFileStat: Equatable, Sendable {
    let kind: LeoFileKind
    let size: UInt64
    let modified: Date
    /// Permission bits only (`mode & 0o7777`).
    let permissions: UInt16

    var version: LeoFileVersion { LeoFileVersion(modified: modified, size: size) }
}

struct LeoFileEntry: Equatable, Sendable {
    let name: String
    let kind: LeoFileKind
    let size: UInt64
    let modified: Date
}

struct LeoFileContents: Equatable, Sendable {
    let data: Data
    let stat: LeoFileStat
}
