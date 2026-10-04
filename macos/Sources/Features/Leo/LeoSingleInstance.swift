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
    /// The holder is quitting: it marked the lock with its pid when its quit
    /// was approved, and holds it only until that process ends (B-092).
    case holderExiting(pid_t)
    case refused(LeoInstanceLockRefusal)
}

/// An exclusive `flock` on `<per-user cache dir>/leo/<bundle ID>.instance.lock`,
/// held until this object is released (for the app, until the process
/// exits). The kernel drops it when the process dies, so a crash never
/// leaves it stuck; `O_CLOEXEC` keeps shells and ssh children Leo spawns
/// from inheriting (and outliving it with) the lock.
///
/// The file is empty while its holder runs. A holder that is quitting
/// writes `exiting <its pid>\n` into it, so a copy launched during the quit
/// waits for that process to end instead of yielding to a copy that is
/// about to be gone (B-092). Whoever takes the lock next empties the file.
final class LeoInstanceLock {
    private static let markPrefix = Array("exiting ".utf8)
    /// More than any mark, so a longer file is never mistaken for one.
    private static let markReadLimit = 32
    private static let maxPIDDigits = 10

    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    static func fileName(for bundleIdentifier: String) -> String { "\(bundleIdentifier).instance.lock" }

    /// Marks the held lock exiting, naming `pid` (this process), through the
    /// held descriptor; the lock stays held until this object goes (the
    /// process ends).
    func markExiting(as pid: pid_t = getpid()) throws {
        guard descriptor >= 0 else { throw LeoInstanceLockError.system(EBADF) }
        let mark = Array("exiting \(pid)\n".utf8)
        let written = mark.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written >= 0 else { throw LeoInstanceLockError.system(errno) }
        guard written == mark.count else { throw LeoInstanceLockError.system(EIO) }
        guard ftruncate(descriptor, off_t(mark.count)) == 0 else { throw LeoInstanceLockError.system(errno) }
    }

    /// The pid in an exact `exiting <pid>\n` mark (1-10 digits, no leading
    /// zero, a positive `pid_t`); nil for anything else.
    static func markedPID(in bytes: [UInt8]) -> pid_t? {
        guard bytes.starts(with: markPrefix), bytes.last == UInt8(ascii: "\n") else { return nil }
        let digits = bytes.dropFirst(markPrefix.count).dropLast()
        guard (1...maxPIDDigits).contains(digits.count), digits.first != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return String(bytes: digits, encoding: .ascii).flatMap { pid_t($0) }
    }

    /// Blocks until process `pid` has exited -- a kqueue `NOTE_EXIT`, no
    /// timeout (principle 5: a quitting copy that hangs is ended by hand) --
    /// when it's a copy that could be holding our lock: `owner`'s, and
    /// `isCopy` (in the app, running this bundle's main executable, B-118).
    /// Returns at once when it's already gone, is this process, or is
    /// anything else: a reused pid, which could be any program and run for
    /// any length of time. "Gone" includes a process that is still exiting:
    /// the kernel reports that before it releases the process's lock, which
    /// `LeoSingleInstance.attempt` allows for.
    ///
    /// The exit is watched before the checks, so a pid taken over in
    /// between never leaves this waiting on the new process: either the
    /// checks see the process being watched, or it has already ended and
    /// the wait returns at once.
    static func waitForExit(of pid: pid_t, owner: uid_t = geteuid(), isCopy: (pid_t) -> Bool) {
        guard pid > 0, pid != getpid() else { return }
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        guard watchExit(of: pid, on: queue), isProcess(pid, ownedBy: owner), isCopy(pid) else { return }
        var event = Darwin.kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0, errno == EINTR {}
    }

    /// Registers a one-shot `NOTE_EXIT` for `pid` on `queue`. False when
    /// there's nothing to watch: `ESRCH` (already gone, a zombie included)
    /// or any other error, which is never waited on either.
    private static func watchExit(of pid: pid_t, on queue: Int32) -> Bool {
        var change = Darwin.kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        // No event list, so an error comes back as -1 and errno, not as an EV_ERROR event.
        while true {
            if kevent(queue, &change, 1, nil, 0, nil) == 0 { return true }
            guard errno == EINTR else { return false }
        }
    }

    /// Same owner-only directory the tunnel sockets use, checked the same
    /// way; the lock file itself must be a regular file `owner` owns with
    /// no other links, and is tightened to 0600. Never blocks: a held lock
    /// is `.holderExiting` when its holder marked it, otherwise `.busy`.
    /// There's no waiting on the lock itself: a copy that waits does so on
    /// the marked process (`waitForExit`) and then tries again, so it never
    /// ends up queued behind a live copy.
    static func acquire(bundleIdentifier: String, in directory: URL, owner: uid_t = geteuid()) -> LeoInstanceLockAttempt {
        withCheckedLockFile(bundleIdentifier, in: directory, owner: owner) { descriptor, path in
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                guard code == EWOULDBLOCK else { return .refused(LeoInstanceLockRefusal(error: .system(code), path: path)) }
                return markedPID(descriptor).map(LeoInstanceLockAttempt.holderExiting) ?? .busy
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

    /// The pid the file's mark names, if it holds exactly one.
    private static func markedPID(_ descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: markReadLimit)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return count > 0 ? markedPID(in: Array(buffer.prefix(count))) : nil
    }

    private static func isProcess(_ pid: pid_t, ownedBy owner: uid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == owner
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

/// Which bundle a process is running, so a marked pid is only waited on
/// while it's still a copy of ours (B-118). Read from the executable's own
/// bundle on disk -- no LaunchServices, which lags behind exits (D-215).
extension LeoInstanceLock {
    /// `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`), which Swift can't import.
    private static let maxExecutablePathBytes = 4 * Int(MAXPATHLEN)
    /// Far more than any app's Info.plist; a bigger file isn't read.
    static let maxInfoPlistBytes = 1 << 20

    /// Whether process `pid` is running bundle `bundleIdentifier`'s main
    /// executable -- from wherever that bundle is (moved, translocated).
    /// False when that can't be read (the process is gone, or its bundle
    /// was removed or replaced), so an unknown process is never waited on.
    static func isCopy(_ pid: pid_t, of bundleIdentifier: String) -> Bool {
        isMainExecutable(executablePath(of: pid), ofBundle: bundleIdentifier)
    }

    /// The path of the executable process `pid` is running (`proc_pidpath`);
    /// nil when it's gone (a zombie included) or that fails.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: maxExecutablePathBytes)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)).prefix { $0 != 0 }, encoding: .utf8)
    }

    /// Whether `path` is `<X>.app/Contents/MacOS/<exe>`, where `X.app`'s
    /// Info.plist declares `bundleIdentifier` and `<exe>` as its
    /// `CFBundleExecutable`: that bundle's main executable, not a helper or
    /// a tool in it.
    static func isMainExecutable(_ path: String?, ofBundle bundleIdentifier: String) -> Bool {
        guard let path else { return false }
        let executable = URL(fileURLWithPath: path)
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let info = infoDictionary(at: contents.appendingPathComponent("Info.plist").path) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
            && info["CFBundleExecutable"] as? String == executable.lastPathComponent
    }

    /// The property list in the regular file at `path`, read fresh (not
    /// through `Bundle`, which caches) and only up to `maxInfoPlistBytes`;
    /// opened non-blocking, so a FIFO there can't hang the launch. Nil for
    /// anything else.
    private static func infoDictionary(at path: String) -> [String: Any]? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxInfoPlistBytes else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? file.read(upToCount: maxInfoPlistBytes + 1), data.count <= maxInfoPlistBytes else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
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
/// Except when the holder is quitting (B-092): it marks the lock with its
/// pid as soon as its quit is approved (and again in
/// `applicationWillTerminate`), and a copy launched then waits for that
/// process to exit and tries again, becoming the primary -- or yielding to
/// whichever copy got there first. Yielding to the quitting copy itself
/// would leave no Leo running. It waits only while that pid is still a copy
/// of this bundle (B-118): a reused pid running anything else is never
/// waited on, only given the release moment `attempt` allows.
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
            do {
                try lock.markExiting()
            } catch {
                LeoSingleInstance.logger.error("couldn't mark the instance lock exiting: \(String(describing: error), privacy: .public)")
            }
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

        /// `reply` for a deferred answer (after `.terminateLater`), marking
        /// the lock exiting first when it's a yes.
        func markingExiting(before reply: @escaping @MainActor (Bool) -> Void) -> @MainActor (Bool) -> Void {
            { shouldTerminate in reply(markingExiting(ifApproved: shouldTerminate)) }
        }
    }

    let bundleIdentifier: String?
    let isTestHost: Bool
    let acquireLock: (String) -> LeoInstanceLockAttempt
    /// Blocks until a process that marked the lock exiting has ended.
    let waitForExit: (pid_t) -> Void
    /// A short pause before trying again while a copy already waited out
    /// still holds its lock (see `maxReleasePauses`).
    let pauseForRelease: () -> Void
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
        return settle(attempt(bundleIdentifier), for: bundleIdentifier)
    }

    /// `acquireLock`, waiting out each holder that marked itself quitting and
    /// then trying again. It never waits on the lock itself, so a copy that
    /// took the lock meanwhile is found, and yielded to.
    ///
    /// The kernel reports a process gone a moment before it releases its
    /// lock, so a try can still find the mark of a copy already waited out.
    /// That's retried after a short pause, up to `maxReleasePauses` times
    /// (seconds; the release takes well under a millisecond): long before
    /// that, the lock is free, or a new holder has emptied the file and is
    /// yielded to. A mark still there after all of them was left on a live
    /// holder that never clears it (an older build): `settle` yields to it.
    private func attempt(_ bundleIdentifier: String) -> LeoInstanceLockAttempt {
        var waitedOut: Set<pid_t> = []
        var pauses = 0
        while true {
            let attempt = acquireLock(bundleIdentifier)
            guard case .holderExiting(let pid) = attempt else { return attempt }
            if waitedOut.insert(pid).inserted {
                Self.logger.log("the copy of \(bundleIdentifier, privacy: .public) holding the lock (pid \(pid, privacy: .public)) is quitting; waiting for it to exit")
                waitForExit(pid)
            } else {
                guard pauses < Self.maxReleasePauses else { return attempt }
                pauses += 1
                pauseForRelease()
            }
        }
    }

    /// Carry on (`.acquired`), yield (D-051) or alert and quit (D-053).
    private func settle(_ attempt: LeoInstanceLockAttempt, for bundleIdentifier: String) -> Claim {
        switch attempt {
        case .acquired(let lock):
            return .primary(lock)
        // `.holderExiting` here: a mark a live holder never cleared (see `attempt`).
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
    /// With `releasePauseMicroseconds`, about 5 s: a bound for a copy
    /// already waited out to let go of its lock (see `attempt`), not a
    /// timeout on anything the user waits for.
    static let maxReleasePauses = 2_500
    private static let releasePauseMicroseconds: useconds_t = 2_000

    /// The real gate: this bundle, the private per-user cache directory,
    /// `NSRunningApplication` activation, a modal alert, and `exit` --
    /// called from `main.swift` before `NSApplicationMain`, so a copy that
    /// yields or refuses never builds an app delegate, a window or a tunnel.
    static func live() -> LeoSingleInstance {
        let mainBundleIdentifier = Bundle.main.bundleIdentifier
        return LeoSingleInstance(
            bundleIdentifier: mainBundleIdentifier,
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
            waitForExit: { pid in
                LeoInstanceLock.waitForExit(of: pid, isCopy: { candidate in
                    mainBundleIdentifier.map { LeoInstanceLock.isCopy(candidate, of: $0) } ?? false
                })
            },
            pauseForRelease: { usleep(releasePauseMicroseconds) },
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
