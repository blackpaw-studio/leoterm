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

    /// The problem, the path, and what to do. Leo never removes or changes
    /// the file itself.
    var message: String { message(showing: path) }

    /// `message` naming the path as `shownPath` (the alert shortens it).
    func message(showing shownPath: String) -> String {
        let path = shownPath
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
    /// The holder is quitting: it marked the lock when its quit was approved
    /// and holds it only until its process ends (B-092).
    case holderExiting
    case refused(LeoInstanceLockRefusal)
}

/// An exclusive `flock` on `<per-user cache dir>/leo/<bundle ID>.instance.lock`,
/// held until this object is released (for the app, until the process
/// exits). The kernel drops it when the process dies, so a crash never
/// leaves it stuck; `O_CLOEXEC` keeps shells and ssh children Leo spawns
/// from inheriting (and outliving it with) the lock.
///
/// The file is empty while its holder runs. A holder that is quitting
/// writes `exitingMark` into it, so a copy launched during the quit waits
/// for the lock instead of yielding to a copy that is about to be gone
/// (B-092). Whoever takes the lock next empties the file again.
final class LeoInstanceLock {
    /// What a quitting holder writes, byte for byte.
    static let exitingMark = Array("exiting\n".utf8)
    /// Enough to tell the mark from anything longer.
    private static let markReadLimit = 16

    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    static func fileName(for bundleIdentifier: String) -> String { "\(bundleIdentifier).instance.lock" }

    /// Marks the held lock exiting, through the held descriptor; the lock
    /// itself stays held until this object goes (the process ends).
    @discardableResult
    func markExiting() -> Bool {
        guard descriptor >= 0 else { return false }
        let written = Self.exitingMark.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return written == Self.exitingMark.count
    }

    /// Same owner-only directory the tunnel sockets use, checked the same
    /// way; the lock file itself must be a regular file `owner` owns with
    /// no other links, and is tightened to 0600. Never blocks: a held lock
    /// is `.holderExiting` when its holder marked it, otherwise `.busy`.
    static func acquire(bundleIdentifier: String, in directory: URL, owner: uid_t = geteuid()) -> LeoInstanceLockAttempt {
        withCheckedLockFile(bundleIdentifier, in: directory, owner: owner) { descriptor, path in
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                guard code == EWOULDBLOCK else { return .refused(LeoInstanceLockRefusal(error: .system(code), path: path)) }
                return isMarkedExiting(descriptor) ? .holderExiting : .busy
            }
            return holding(descriptor, path: path)
        }
    }

    /// `acquire`, with the same checks on the file, but blocking in `flock`
    /// until the holder lets go: for a holder marked exiting, whose process
    /// is about to end. No timeout (principle 5): a holder that hangs while
    /// quitting is ended by hand, and this copy then carries on. `O_NONBLOCK`
    /// on the descriptor doesn't affect `flock`.
    static func waitAndAcquire(bundleIdentifier: String, in directory: URL, owner: uid_t = geteuid()) -> LeoInstanceLockAttempt {
        withCheckedLockFile(bundleIdentifier, in: directory, owner: owner) { descriptor, path in
            while flock(descriptor, LOCK_EX) != 0 {
                let code = errno
                guard code == EINTR else { return .refused(LeoInstanceLockRefusal(error: .system(code), path: path)) }
            }
            return holding(descriptor, path: path)
        }
    }

    /// Opens and checks the lock file, then hands its descriptor to `lock`,
    /// and closes it unless `lock` returns `.acquired` (which then owns it).
    private static func withCheckedLockFile(
        _ bundleIdentifier: String, in directory: URL, owner: uid_t,
        lock: (_ descriptor: Int32, _ path: String) -> LeoInstanceLockAttempt
    ) -> LeoInstanceLockAttempt {
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
        let attempt = lock(descriptor, path)
        if case .acquired = attempt { return attempt }
        close(descriptor)
        return attempt
    }

    /// The lock is ours: empty the file before anything else, so the mark
    /// the previous holder left never makes a later copy wait on this live
    /// one. If it can't be emptied, refuse (D-053) rather than run with it.
    private static func holding(_ descriptor: Int32, path: String) -> LeoInstanceLockAttempt {
        guard ftruncate(descriptor, 0) == 0 else {
            return .refused(LeoInstanceLockRefusal(error: .system(errno), path: path))
        }
        return .acquired(LeoInstanceLock(descriptor: descriptor))
    }

    /// The file holds exactly `exitingMark`.
    private static func isMarkedExiting(_ descriptor: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: markReadLimit)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return count >= 0 && Array(buffer.prefix(count)) == exitingMark
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
/// Except when the holder is quitting (B-092): it marks the lock as soon as
/// its quit is approved (and again in `applicationWillTerminate`), and a
/// copy launched then waits for it to exit and carries on as the primary.
/// Yielding would activate a copy that is about to be gone and leave no
/// Leo running.
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

        /// Marks a held lock exiting once the quit is final, so a copy
        /// launched during it waits for this one to go. Nothing to mark for
        /// any other claim.
        func markExiting() {
            guard case .primary(let lock) = self else { return }
            guard !lock.markExiting() else { return }
            let code = errno
            LeoSingleInstance.logger.error("couldn't mark the instance lock exiting errno=\(code, privacy: .public)")
        }

        /// `applicationShouldTerminate`'s `reply`, marking the lock exiting
        /// when it lets the quit go ahead. AppKit runs
        /// `applicationWillTerminate` only ~50 ms after that, which is the
        /// very window B-092 hit; a later or cancelled quit isn't final yet.
        func markingExiting(ifApproved reply: NSApplication.TerminateReply) -> NSApplication.TerminateReply {
            if reply == .terminateNow { markExiting() }
            return reply
        }

        /// The same for `NSApp.reply(toApplicationShouldTerminate:)`.
        func markingExiting(ifApproved shouldTerminate: Bool) -> Bool {
            if shouldTerminate { markExiting() }
            return shouldTerminate
        }
    }

    let bundleIdentifier: String?
    let isTestHost: Bool
    let acquireLock: (String) -> LeoInstanceLockAttempt
    /// Blocks until the lock is free; only called when `acquireLock` found
    /// its holder quitting.
    let waitForLock: (String) -> LeoInstanceLockAttempt
    let activateOther: (String) -> Void
    let alert: (LeoInstanceLockRefusal) -> Void
    let terminate: (Int32) -> Void

    /// A hosted XCTest run, three facts together: the injector library is
    /// loaded; the executable of one of this app's `.xctest` plug-ins is
    /// loaded (by the time `main.swift` runs, the injector has loaded it,
    /// under `xcodebuild` and `-XCTest` alike); and the environment names
    /// this app -- the injector's target is this executable (a direct
    /// `-XCTest` run) or, as `xcodebuild test` launches it
    /// (`XCInjectBundleInto=unused`), `XCTestBundlePath` is that plug-in.
    /// Environment variables alone (which a child can inherit) are never enough.
    static func isTestHost(environment: [String: String], executablePath: String?, bundlePath: String?, loadedImages: [String]) -> Bool {
        let injectorLoaded = loadedImages.contains { URL(fileURLWithPath: $0).lastPathComponent == "libXCTestBundleInject.dylib" }
        guard injectorLoaded, let bundle = bundlePath.flatMap(realPath) else { return false }
        let testBundles = loadedPlugInTestBundles(in: bundle, loadedImages: loadedImages)
        guard !testBundles.isEmpty else { return false }
        return injectsInto(executablePath, environment: environment)
            || namesTestBundle(testBundles, in: bundle, environment: environment)
    }

    private static func injectsInto(_ executablePath: String?, environment: [String: String]) -> Bool {
        guard let injectedInto = environment["XCInjectBundleInto"].flatMap(realPath),
              let executablePath = executablePath.flatMap(realPath) else { return false }
        return injectedInto == executablePath
    }

    /// `XCTestBundlePath` (absolute, or relative to the app) resolves to one
    /// of `testBundles`.
    private static func namesTestBundle(_ testBundles: Set<String>, in bundle: String, environment: [String: String]) -> Bool {
        guard let testBundle = environment["XCTestBundlePath"], !testBundle.isEmpty else { return false }
        let candidate = testBundle.hasPrefix("/") ? testBundle : bundle + "/" + testBundle
        return realPath(candidate).map(testBundles.contains) ?? false
    }

    /// The resolved `.xctest` directories directly in this app's (resolved)
    /// `Contents/PlugIns` whose declared executable is a loaded image.
    private static func loadedPlugInTestBundles(in bundle: String, loadedImages: [String]) -> Set<String> {
        guard let plugIns = realPath(bundle + "/Contents/PlugIns"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: plugIns) else { return [] }
        let loaded = Set(loadedImages.compactMap(realPath))
        return Set(names.filter { $0.hasSuffix(".xctest") }.compactMap { name -> String? in
            guard let testBundle = realPath(plugIns + "/" + name),
                  URL(fileURLWithPath: testBundle).deletingLastPathComponent().path == plugIns,
                  let executable = Bundle(path: testBundle)?.executableURL.flatMap({ realPath($0.path) }),
                  loaded.contains(executable) else { return nil }
            return testBundle
        })
    }

    static func isRunningAsTestHost() -> Bool {
        isTestHost(
            environment: ProcessInfo.processInfo.environment,
            executablePath: Bundle.main.executablePath,
            bundlePath: Bundle.main.bundlePath,
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
        let attempt = acquireLock(bundleIdentifier)
        guard case .holderExiting = attempt else { return settle(attempt, for: bundleIdentifier) }
        Self.logger.log("the copy of \(bundleIdentifier, privacy: .public) holding the lock is quitting; waiting for it to exit")
        return settle(waitForLock(bundleIdentifier), for: bundleIdentifier)
    }

    /// Carry on (`.acquired`), yield (D-051) or alert and quit (D-053).
    private func settle(_ attempt: LeoInstanceLockAttempt, for bundleIdentifier: String) -> Claim {
        switch attempt {
        case .acquired(let lock):
            return .primary(lock)
        // A holder still quitting after the wait: yield rather than wait again.
        case .busy, .holderExiting:
            Self.logger.log("another copy of \(bundleIdentifier, privacy: .public) is running; activating it and quitting")
            activateOther(bundleIdentifier)
            terminate(0)
            return .yielded
        case .refused(let refusal):
            Self.logger.error("instance lock refused; not starting reason=\(refusal.message, privacy: .public)")
            alert(refusal)
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
                inLockDirectory { directory in
                    #if DEBUG
                    if let forced = forcedStartFailure(
                        environment: ProcessInfo.processInfo.environment, bundleIdentifier: bundleIdentifier, directory: directory
                    ) {
                        return .refused(forced)
                    }
                    #endif
                    return LeoInstanceLock.acquire(bundleIdentifier: bundleIdentifier, in: directory)
                }
            },
            waitForLock: { bundleIdentifier in
                inLockDirectory { LeoInstanceLock.waitAndAcquire(bundleIdentifier: bundleIdentifier, in: $0) }
            },
            activateOther: activateRunningCopy,
            alert: presentCannotStart,
            terminate: { exit($0) }
        )
    }

    /// `body` with the private per-user lock directory; refused when macOS
    /// reports no cache directory.
    private static func inLockDirectory(_ body: (URL) -> LeoInstanceLockAttempt) -> LeoInstanceLockAttempt {
        guard let directory = LeoControlSocketDirectory.default else {
            return .refused(LeoInstanceLockRefusal(error: .noCacheDirectory, path: "_CS_DARWIN_USER_CACHE_DIR"))
        }
        return body(directory)
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

    #if DEBUG
    /// `LEO_FORCE_START_FAILURE=1` makes a debug build refuse its real lock
    /// path as hard-linked, without opening or touching the file, so the
    /// "Leo can’t start" alert can be seen. Compiled out of release builds.
    static func forcedStartFailure(environment: [String: String], bundleIdentifier: String, directory: URL) -> LeoInstanceLockRefusal? {
        guard environment["LEO_FORCE_START_FAILURE"] == "1" else { return nil }
        let path = directory.appendingPathComponent(LeoInstanceLock.fileName(for: bundleIdentifier)).path
        return LeoInstanceLockRefusal(error: .linked, path: path)
    }
    #endif

    /// The modal "Leo can’t start" alert (`LeoCannotStartAlert`); returns on
    /// Quit. Runs before `NSApplicationMain`, on the main thread.
    private static func presentCannotStart(_ refusal: LeoInstanceLockRefusal) {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(ignoringOtherApps: true)
            }
            LeoCannotStartAlertPresenter(content: LeoCannotStartAlert(refusal: refusal)).run()
        }
    }
}
