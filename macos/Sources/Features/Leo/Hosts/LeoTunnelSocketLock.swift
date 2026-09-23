import Darwin
import Foundation

enum LeoTunnelSocketLockError: Error, Equatable, Sendable {
    /// Another running copy of the app holds the lock: the path is its
    /// tunnel's.
    case busy
    /// The lock file can't be used (a symlink, not a regular file, another
    /// user's, or an `open`/`flock` failure). Nothing at the path is touched.
    case unusable(String)
}

/// Ownership of a tunnel socket path (D-049): an exclusive `flock` on
/// `<path>.lock`, held by the running app for as long as its tunnel for
/// that path lives. The kernel drops it when the app exits however it
/// exits, so a held lock always means a live owner and a free one means
/// nobody live owns the path -- no connect probe (whose ECONNREFUSED a live
/// listener with a full backlog also returns) is needed to tell them apart.
///
/// Opened `O_CLOEXEC`, so ssh never inherits it: the lock is the app's, not
/// the child's. The lock file is never unlinked (that would let two
/// holders lock different inodes); if the OS purges the directory under a
/// held lock, the holder's socket is purged with it and its tunnel has to
/// reconnect anyway, when it contends for the new lock file like anyone.
final class LeoTunnelSocketLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    static func lockPath(for socketPath: String) -> String { socketPath + ".lock" }

    /// Takes the lock for `socketPath` without waiting. Refuses a lock file
    /// that is a symlink, not a regular file, or not `owner`'s.
    static func acquire(for socketPath: String, owner: uid_t = geteuid()) throws -> LeoTunnelSocketLock {
        let path = lockPath(for: socketPath)
        // O_NONBLOCK: a FIFO planted at the path must not hang the open.
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            throw LeoTunnelSocketLockError.unusable(errno == ELOOP ? "the lock file is a symlink" : describe(errno))
        }
        do {
            try check(descriptor, owner: owner)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw errno == EWOULDBLOCK ? LeoTunnelSocketLockError.busy : .unusable(describe(errno))
            }
        } catch {
            close(descriptor)
            throw error
        }
        return LeoTunnelSocketLock(descriptor: descriptor)
    }

    /// Idempotent. Closing the descriptor drops the lock.
    func release() {
        let released: Int32? = lock.withLock {
            defer { descriptor = nil }
            return descriptor
        }
        if let released { close(released) }
    }

    private static func check(_ descriptor: Int32, owner: uid_t) throws {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw LeoTunnelSocketLockError.unusable(describe(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LeoTunnelSocketLockError.unusable("the lock file is not a regular file") }
        guard info.st_uid == owner else { throw LeoTunnelSocketLockError.unusable("the lock file belongs to another user") }
    }

    private static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
}
