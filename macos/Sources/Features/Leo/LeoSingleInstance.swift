import AppKit
import Darwin
import Foundation
import OSLog

enum LeoInstanceLockError: Error, Equatable, Sendable {
    /// Not a plain reverse-DNS name, so it can't safely name a file.
    case invalidBundleIdentifier
    /// The lock directory failed `LeoControlSocketDirectory.prepare`.
    case directory(LeoControlSocketDirectoryError)
    /// A symlink, directory, FIFO or anything but a regular file.
    case notARegularFile
    case notOwned
    /// Another name points at the same file, which someone else could
    /// then swap or unlink behind the lock.
    case linked
    case system(Int32)
}

enum LeoInstanceLockAttempt {
    case acquired(LeoInstanceLock)
    /// Another live process holds the lock.
    case busy
    case refused(any Error)
}

/// An exclusive `flock` on `<per-user cache dir>/leo/<bundle ID>.instance.lock`,
/// held until this object is released (for the app, until the process
/// exits). The kernel drops it when the process dies, so a crash never
/// leaves it stuck; `O_CLOEXEC` keeps shells and ssh children Leo spawns
/// from inheriting (and outliving it with) the lock.
final class LeoInstanceLock {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    static func fileName(for bundleIdentifier: String) -> String { "\(bundleIdentifier).instance.lock" }

    /// Same owner-only directory the tunnel sockets use, checked the same
    /// way; the lock file itself must be a regular file `owner` owns with
    /// no other links, and is tightened to 0600.
    static func acquire(bundleIdentifier: String, in directory: URL, owner: uid_t = geteuid()) -> LeoInstanceLockAttempt {
        guard isSafeFileComponent(bundleIdentifier) else { return .refused(LeoInstanceLockError.invalidBundleIdentifier) }
        do {
            try LeoControlSocketDirectory.prepare(directory, owner: owner)
        } catch let error as LeoControlSocketDirectoryError {
            return .refused(LeoInstanceLockError.directory(error))
        } catch {
            return .refused(error)
        }
        let path = directory.appendingPathComponent(fileName(for: bundleIdentifier)).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return .refused(errno == ELOOP ? LeoInstanceLockError.notARegularFile : LeoInstanceLockError.system(errno))
        }
        if let error = checkLockFile(descriptor, owner: owner) {
            close(descriptor)
            return .refused(error)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .busy : .refused(LeoInstanceLockError.system(code))
        }
        return .acquired(LeoInstanceLock(descriptor: descriptor))
    }

    private static func checkLockFile(_ descriptor: Int32, owner: uid_t) -> LeoInstanceLockError? {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { return .system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notARegularFile }
        guard info.st_uid == owner else { return .notOwned }
        guard info.st_nlink == 1 else { return .linked }
        guard info.st_mode & 0o077 != 0 else { return nil }
        return fchmod(descriptor, 0o600) == 0 ? nil : .system(errno)
    }

    private static func isSafeFileComponent(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Leo is single-instance per bundle ID (D-051). Copies of one bundle share
/// its tunnel state -- the orphan record in its defaults and the sockets in
/// `LeoControlSocketDirectory` -- and `LeoTunnel.removeStaleSocket` and
/// `LeoTunnelOrphanStore.reapAtLaunch` rely on no other copy being alive.
/// So at launch, before `AppDelegate` or `LeoRuntime` exist, a copy that
/// finds the instance lock held activates the running copy and quits
/// without touching any of that state. Release and debug bundles have
/// different IDs and so independent locks.
///
/// Fails open: when the lock can't be checked safely (an unsafe directory,
/// a symlinked or foreign lock file), Leo launches anyway and logs it. A
/// test host (the XCTest bundle runs inside the debug Leo.app) never takes
/// the lock or quits.
struct LeoSingleInstance {
    enum Claim {
        /// This copy holds the lock; keep it alive for the process's life.
        case primary(LeoInstanceLock)
        /// Another copy holds it; that copy was activated and this one told to terminate.
        case yielded
        case skipped(String)
        case failedOpen(String)
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// Set by xcodebuild/`XCTestBundleInject` for a hosted test run.
    static let testHostVariables = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"]

    let bundleIdentifier: String?
    let environment: [String: String]
    let acquireLock: (String) -> LeoInstanceLockAttempt
    let activateOther: (String) -> Void
    let terminate: () -> Void

    static func isTestHost(_ environment: [String: String]) -> Bool {
        testHostVariables.contains { environment[$0] != nil }
    }

    func claim() -> Claim {
        guard !Self.isTestHost(environment) else { return .skipped("test host") }
        guard let bundleIdentifier else {
            Self.logger.log("no bundle identifier; single-instance check skipped")
            return .skipped("no bundle identifier")
        }
        switch acquireLock(bundleIdentifier) {
        case .acquired(let lock):
            return .primary(lock)
        case .busy:
            Self.logger.log("another copy of \(bundleIdentifier, privacy: .public) is running; activating it and quitting")
            activateOther(bundleIdentifier)
            terminate()
            return .yielded
        case .refused(let error):
            let reason = String(describing: error)
            Self.logger.error("instance lock unavailable; launching without it error=\(reason, privacy: .public)")
            return .failedOpen(reason)
        }
    }
}

extension LeoSingleInstance {
    /// The real gate: this bundle, the private per-user cache directory,
    /// `NSRunningApplication` activation, and `exit(0)` -- called from
    /// `main.swift` before `NSApplicationMain`, so a yielding copy never
    /// builds an app delegate, a window or a tunnel.
    static func live() -> LeoSingleInstance {
        LeoSingleInstance(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            acquireLock: { bundleIdentifier in
                guard let directory = LeoControlSocketDirectory.default else {
                    return .refused(LeoInstanceLockError.system(ENOENT))
                }
                return LeoInstanceLock.acquire(bundleIdentifier: bundleIdentifier, in: directory)
            },
            activateOther: activateRunningCopy,
            terminate: { exit(0) }
        )
    }

    private static func activateRunningCopy(of bundleIdentifier: String) {
        let own = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != own }
        guard let other else {
            logger.log("instance lock held but no running copy found to activate")
            return
        }
        if #available(macOS 14.0, *) {
            other.activate()
        } else {
            other.activate(options: [])
        }
    }
}
