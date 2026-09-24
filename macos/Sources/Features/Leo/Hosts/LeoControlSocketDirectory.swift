import Darwin
import Foundation

enum LeoControlSocketDirectoryError: Error, Equatable, Sendable {
    /// A symlink, file or anything else sits at the directory's path.
    case notADirectory
    /// The directory exists but belongs to another user.
    case notOwned
    /// The parent is writable by others without the sticky bit, so the
    /// checked directory could be renamed away and replaced after the check.
    case unsafeParent
    case system(Int32)
}

/// Where the tunnel's sockets live -- the forwarded daemon socket and the
/// ControlMaster socket: `<per-user cache dir>/leo/`.
///
/// ssh leaves a control path 86 bytes (`LeoSSHCommand.isValidControlPath`),
/// which `~/.leo/state/leoterm/` exhausts for any home directory longer
/// than ~33 characters. The Darwin per-user cache directory
/// (`/var/folders/xx/<30 chars>/C/`, 49 bytes) has a fixed length whatever
/// the home directory, is created by the OS owned by the user with mode
/// 0700 (so no other user can pre-create or swap anything inside it), and
/// -- unlike the sibling `T/` -- isn't swept of old files while the app
/// runs, which would unlink a long-lived master's socket. 49 + `leo/` +
/// the 33-byte `controlSocketFileName` is exactly 86: both halves are
/// fixed-length, so it fits for every user or for none, never by accident.
/// The forwarded socket (`tunnelSocketFileName`, 29 bytes) takes 82 of
/// the 100 bytes `LeoSSHCommand` allows it, on the same terms.
enum LeoControlSocketDirectory {
    static let name = "leo"

    /// nil only if the OS can't report the cache directory.
    static var `default`: URL? {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) == length else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let base = String(bytes: bytes, encoding: .utf8), base.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Creates `directory` owner-only, or checks an existing one: never
    /// through a symlink, only if `owner` owns it (tightening it to 0700
    /// if looser), and only in a parent nobody else can rewrite. Called
    /// before every use of a path inside it.
    static func prepare(_ directory: URL, owner: uid_t = geteuid()) throws {
        try checkParent(directory.deletingLastPathComponent().path, owner: owner)
        let path = directory.path
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw LeoControlSocketDirectoryError.system(errno) }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP || errno == ENOTDIR ? LeoControlSocketDirectoryError.notADirectory : .system(errno)
        }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw LeoControlSocketDirectoryError.system(errno) }
        guard info.st_uid == owner else { throw LeoControlSocketDirectoryError.notOwned }
        guard info.st_mode & 0o077 != 0 else { return }
        guard fchmod(descriptor, 0o700) == 0 else { throw LeoControlSocketDirectoryError.system(errno) }
    }

    /// Follows symlinks (`/var` and `/tmp` are root's symlinks into
    /// `/private`): the parent must be a directory owned by `owner` or
    /// root, and sticky if anyone else can write it.
    private static func checkParent(_ path: String, owner: uid_t) throws {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { throw LeoControlSocketDirectoryError.system(errno) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let isOwnedSafely = info.st_uid == owner || info.st_uid == 0
        let othersCanRewrite = info.st_mode & 0o022 != 0 && info.st_mode & S_ISVTX == 0
        guard isDirectory, isOwnedSafely, !othersCanRewrite else { throw LeoControlSocketDirectoryError.unsafeParent }
    }
}
