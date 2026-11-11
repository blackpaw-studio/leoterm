import Darwin
import Foundation

/// A running helper: its pid and the app's end of the socketpair.
struct LeoPluginHostProcess {
    let pid: pid_t
    let fd: Int32
}

/// Starts one helper process. Injected so the connection stays testable.
protocol LeoPluginHostLauncher {
    func launch() throws -> LeoPluginHostProcess
}

enum LeoPluginHostLaunchError: Error, Equatable {
    case helperMissing(String)
    case socketpair(errno: Int32)
    case spawn(errno: Int32)
}

/// Spawns `Contents/Helpers/LeoPluginHost` with `posix_spawn`.
///
/// Hardening that matters (see `docs/plans/2026-11-10-plugin-platform-spike.md`):
/// - The helper gets one end of a `socketpair` on fd 3 and nothing else:
///   `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every other inherited descriptor.
/// - The app's end is `FD_CLOEXEC` and `SO_NOSIGPIPE`, so sibling helpers
///   never inherit it (a helper must see EOF when the app dies) and a write
///   to a killed helper can't terminate the app.
/// - The helper's environment is empty: no tokens or paths leak into plugin code.
struct LeoPluginPosixLauncher: LeoPluginHostLauncher {
    let helperURL: URL

    /// The helper embedded in the running app bundle.
    static func embedded(in bundle: Bundle = .main) -> LeoPluginPosixLauncher {
        LeoPluginPosixLauncher(
            helperURL: bundle.bundleURL.appendingPathComponent("Contents/Helpers/LeoPluginHost"))
    }

    func launch() throws -> LeoPluginHostProcess {
        let path = helperURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LeoPluginHostLaunchError.helperMissing(path)
        }
        Self.ignoreSIGPIPE()

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw LeoPluginHostLaunchError.socketpair(errno: errno)
        }
        let appEnd = pair[0]
        let helperEnd = pair[1]
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var on: Int32 = 1
        _ = setsockopt(appEnd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        // stdin/out/err pass through (unchanged, so a debugger still sees helper
        // stderr); the socket lands on fd 3. dup2 to a different fd clears CLOEXEC.
        for fd: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, fd, fd) }
        posix_spawn_file_actions_adddup2(&actions, helperEnd, 3)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(helperEnd)
        guard status == 0 else {
            close(appEnd)
            throw LeoPluginHostLaunchError.spawn(errno: status)
        }
        return LeoPluginHostProcess(pid: pid, fd: appEnd)
    }

    private static let ignoreSIGPIPEOnce: Void = { signal(SIGPIPE, SIG_IGN) }()
    private static func ignoreSIGPIPE() { _ = ignoreSIGPIPEOnce }
}
