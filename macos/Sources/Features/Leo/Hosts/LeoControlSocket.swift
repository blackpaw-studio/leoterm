import Darwin
import Foundation

/// What occupies a ControlMaster path, as far as removing it is concerned.
enum LeoControlSocketState: Equatable, Sendable {
    case absent
    /// A socket something is still listening on -- possibly another app
    /// instance's master. Never removed.
    case live
    /// A socket nobody listens on (`connect` refused): left by a master
    /// that died without cleanup. Safe to remove.
    case stale
    /// A regular file, directory, symlink or anything else. Never removed.
    case notASocket
    /// A socket another user owns, whoever listens on it: possibly a fake
    /// master planted to see every file (ssh's mux client never checks the
    /// master's uid). Never probed, used or removed.
    case foreign
    /// `lstat` or `connect` failed with this errno. Never removed.
    case unknown(Int32)
}

/// What sits at a socket path by `lstat` alone -- no connect probe.
enum LeoSocketOccupant: Equatable, Sendable {
    case absent
    /// A socket `owner` owns, live or not.
    case ownSocket
    case foreign
    case notASocket
    case unknown(Int32)
}

/// Inspects and (only when provably stale) removes a ControlMaster socket.
/// Uses `lstat`, so a symlink is never followed. Only a socket `owner`
/// (this process's user) owns is ever judged live or stale.
enum LeoControlSocket {
    static func inspect(_ path: String, owner: uid_t = geteuid()) -> LeoControlSocketState {
        switch occupant(path, owner: owner) {
        case .absent: return .absent
        case .ownSocket: return probe(path)
        case .foreign: return .foreign
        case .notASocket: return .notASocket
        case .unknown(let code): return .unknown(code)
        }
    }

    /// Classifies `path` without connecting to it. Tunnel sockets are judged
    /// by this plus their path lock (`LeoTunnelSocketLock`), never a probe.
    static func occupant(_ path: String, owner: uid_t = geteuid()) -> LeoSocketOccupant {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .unknown(errno) }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .notASocket }
        guard info.st_uid == owner else { return .foreign }
        return .ownSocket
    }

    /// Unlinks `path` only if it's a socket `owner` owns, without probing
    /// it: for a tunnel socket whose path lock the caller holds, which
    /// already proves nobody live owns it. Returns what was there.
    @discardableResult
    static func removeOwnedSocket(_ path: String, owner: uid_t = geteuid()) -> LeoSocketOccupant {
        let found = occupant(path, owner: owner)
        guard found == .ownSocket else { return found }
        guard unlink(path) == 0 || errno == ENOENT else { return .unknown(errno) }
        return found
    }

    /// Unlinks `path` only when `inspect` finds it `.stale`, and returns
    /// what `inspect` found. A master binding the path again between the
    /// probe and the unlink is the one window left; only this app instance
    /// ever binds its own (bundle-scoped) path, and it does so only after
    /// this returns.
    @discardableResult
    static func removeIfStale(_ path: String, owner: uid_t = geteuid()) -> LeoControlSocketState {
        let state = inspect(path, owner: owner)
        guard state == .stale else { return state }
        guard unlink(path) == 0 || errno == ENOENT else { return .unknown(errno) }
        return .stale
    }

    /// `connect` succeeding means live; ECONNREFUSED or ENOENT means stale.
    /// On Darwin, ECONNREFUSED can also come from a live listener whose
    /// accept backlog is full, so a busy master could be judged stale and
    /// unlinked. Accepted: the path is scoped to this app bundle and to the
    /// host's connection settings (`controlSocketFileName(instance:)`), so
    /// the only listener it can belong to is this instance's own master for
    /// the same server, and only a previous run's would be there.
    private static func probe(_ path: String) -> LeoControlSocketState {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unknown(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unknown(errno) }
        defer { close(descriptor) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .live }
        switch errno {
        case ECONNREFUSED, ENOENT: return .stale
        default: return .unknown(errno)
        }
    }
}
