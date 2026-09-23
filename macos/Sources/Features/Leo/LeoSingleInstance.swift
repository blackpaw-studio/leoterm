import AppKit
import Darwin
import Foundation
import MachO
import OSLog

enum LeoInstanceLockError: Error, Equatable, Sendable {
    /// Not a plain reverse-DNS name, so it can't safely name a file.
    case invalidBundleIdentifier
    /// macOS didn't report a per-user cache directory.
    case noCacheDirectory
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

/// Why the lock couldn't be taken safely, and where.
struct LeoInstanceLockRefusal: Error, Equatable, Sendable {
    let error: LeoInstanceLockError
    /// The offending file or directory (the bundle ID for `.invalidBundleIdentifier`).
    let path: String

    /// The informative text of the "Leo can’t start" alert: the problem,
    /// the path, and what to do. Leo never removes or changes the file itself.
    var message: String {
        let fix = "Remove it and open Leo again."
        switch error {
        case .invalidBundleIdentifier: return "This copy of Leo has an unusable bundle identifier (\(path)). Reinstall Leo."
        case .noCacheDirectory: return "macOS didn’t report a cache folder for your account, so Leo can’t make sure only one copy runs."
        case .directory(.notADirectory): return "\(path) is a symlink or not a folder. \(fix)"
        case .directory(.notOwned): return "\(path) belongs to another user. \(fix)"
        case .directory(.unsafeParent): return "The folder containing \(path) can be changed by other users."
        case .directory(.system(let code)): return "\(path) can’t be checked: \(String(cString: strerror(code)))."
        case .notARegularFile: return "\(path) is a symlink or not a regular file. \(fix)"
        case .notOwned: return "\(path) belongs to another user. \(fix)"
        case .linked: return "\(path) has other hard links. \(fix)"
        case .system(let code): return "\(path) can’t be locked: \(String(cString: strerror(code)))."
        }
    }
}

enum LeoInstanceLockAttempt {
    case acquired(LeoInstanceLock)
    /// Another live process holds the lock.
    case busy
    case refused(LeoInstanceLockRefusal)
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
        guard isSafeFileComponent(bundleIdentifier) else {
            return .refused(LeoInstanceLockRefusal(error: .invalidBundleIdentifier, path: bundleIdentifier))
        }
        do {
            try LeoControlSocketDirectory.prepare(directory, owner: owner)
        } catch {
            let reason = error as? LeoControlSocketDirectoryError ?? .system(EINVAL)
            return .refused(LeoInstanceLockRefusal(error: .directory(reason), path: directory.path))
        }
        let path = directory.appendingPathComponent(fileName(for: bundleIdentifier)).path
        let refuse = { (error: LeoInstanceLockError) in LeoInstanceLockAttempt.refused(LeoInstanceLockRefusal(error: error, path: path)) }
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return refuse(errno == ELOOP || errno == EISDIR ? .notARegularFile : .system(errno))
        }
        if let error = checkLockFile(descriptor, owner: owner) {
            close(descriptor)
            return refuse(error)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .busy : refuse(.system(code))
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
/// Fails closed: when the lock can't be taken safely (an unsafe directory,
/// a symlinked, foreign or hard-linked lock file), another copy could be
/// running unseen, so Leo says why in one alert and exits 1, leaving the
/// offending file alone. A test host (the XCTest bundle runs inside the
/// debug Leo.app) never takes the lock or quits.
struct LeoSingleInstance {
    enum Claim {
        /// This copy holds the lock; keep it alive for the process's life.
        case primary(LeoInstanceLock)
        /// Another copy holds it: that copy was activated and this one exits 0.
        case yielded
        case skipped(String)
        /// The lock couldn't be taken safely: alerted, and this copy exits 1.
        case refused(LeoInstanceLockRefusal)
    }

    let bundleIdentifier: String?
    let isTestHost: Bool
    let acquireLock: (String) -> LeoInstanceLockAttempt
    let activateOther: (String) -> Void
    let alert: (String) -> Void
    let terminate: (Int32) -> Void

    /// A hosted XCTest run: the injector names this very executable AND the
    /// injector library is actually loaded into this process. Environment
    /// variables alone (which a child can inherit) are never enough.
    static func isTestHost(environment: [String: String], executablePath: String?, loadedImages: [String]) -> Bool {
        guard let injectedInto = environment["XCInjectBundleInto"].flatMap(realPath),
              let executablePath = executablePath.flatMap(realPath),
              injectedInto == executablePath else { return false }
        return loadedImages.contains { URL(fileURLWithPath: $0).lastPathComponent == "libXCTestBundleInject.dylib" }
    }

    static func isRunningAsTestHost() -> Bool {
        isTestHost(
            environment: ProcessInfo.processInfo.environment,
            executablePath: Bundle.main.executablePath,
            loadedImages: loadedImagePaths()
        )
    }

    func claim() -> Claim {
        guard !isTestHost else { return .skipped("test host") }
        // No bundle ID means no bundle-keyed defaults or socket paths to share.
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
            terminate(0)
            return .yielded
        case .refused(let refusal):
            Self.logger.error("instance lock refused; not starting reason=\(refusal.message, privacy: .public)")
            alert(refusal.message)
            terminate(1)
            return .refused(refusal)
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension LeoSingleInstance {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// The real gate: this bundle, the private per-user cache directory,
    /// `NSRunningApplication` activation, a modal alert, and `exit` --
    /// called from `main.swift` before `NSApplicationMain`, so a copy that
    /// yields or refuses never builds an app delegate, a window or a tunnel.
    static func live() -> LeoSingleInstance {
        LeoSingleInstance(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isTestHost: isRunningAsTestHost(),
            acquireLock: { bundleIdentifier in
                guard let directory = LeoControlSocketDirectory.default else {
                    return .refused(LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"))
                }
                return LeoInstanceLock.acquire(bundleIdentifier: bundleIdentifier, in: directory)
            },
            activateOther: activateRunningCopy,
            alert: presentCannotStart,
            terminate: { exit($0) }
        )
    }

    /// Paths of every image dyld has loaded into this process.
    static func loadedImagePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
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

    /// One plain modal alert with a single Quit button; runs before
    /// `NSApplicationMain`, on the main thread.
    private static func presentCannotStart(_ message: String) {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(ignoringOtherApps: true)
            }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Leo can’t start"
            alert.informativeText = message
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
    }
}
