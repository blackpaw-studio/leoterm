import Darwin
import Foundation

/// Captures the user's login-shell `PATH`: a daemon started by launchd gets
/// a bare environment, so `claude`, `git` and friends would not resolve.
struct LeoLoginPathProbe: Sendable {
    static let timeout: TimeInterval = 10
    static let arguments = ["-l", "-c", "/usr/bin/printenv PATH"]

    let runner: any LeoProcessRunning
    /// The account's login shell, from the password database.
    let userShell: @Sendable () -> String?
    /// The shells listed in `/etc/shells`.
    let allowedShells: @Sendable () -> [String]

    static func live(runner: any LeoProcessRunning) -> Self {
        Self(
            runner: runner,
            userShell: {
                guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
                return String(cString: shell)
            },
            allowedShells: {
                parseEtcShells((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "")
            }
        )
    }

    /// The validated login `PATH`, or nil to fall back to the static one.
    func loginPath() async -> String? {
        guard let shell = userShell(), shell.hasPrefix("/"), allowedShells().contains(shell) else { return nil }
        guard let result = try? await runner.run(executable: shell, arguments: Self.arguments, timeout: Self.timeout),
              result.status == 0,
              let output = String(bytes: result.stdout, encoding: .utf8) else { return nil }
        return Self.validatedPath(output)
    }

    /// One line (an optional trailing newline aside) of colon-separated
    /// absolute directories. Anything a noisy `.zshrc` prints around it fails.
    static func validatedPath(_ output: String) -> String? {
        let line = output.hasSuffix("\n") ? String(output.dropLast()) : output
        let entries = line.split(separator: ":", omittingEmptySubsequences: false)
        let isClean = entries.allSatisfy { $0.hasPrefix("/") && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        return isClean ? line : nil
    }

    static func parseEtcShells(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }
}

/// The environment the app asks the daemon to apply (marker `env`, D5).
enum LeoDaemonEnvironment {
    /// Matches the static LaunchAgent plist's `PATH` (A4).
    static let staticPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private static let droppedKeys: Set = ["SSH_AUTH_SOCK", "TERM_SESSION_ID", "LEO_CONFIG"]
    private static let droppedPrefixes = ["TMUX", "__CF", "XPC_"]

    /// - Parameters:
    ///   - captured: the environment handed over by `leo service handover`, if any.
    ///   - loginPath: a validated login-shell `PATH`, used when `captured` has none.
    static func merge(captured: [String: String]?, loginPath: String?, home: String, bundledTerminfo: String) -> [String: String] {
        var env = (captured ?? [:]).filter { key, _ in
            !droppedKeys.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
        let basePath = [env["PATH"], loginPath].compactMap { $0 }.first { !$0.isEmpty }
        let entries = ["\(home)/.local/bin"] + (basePath?.split(separator: ":").map(String.init) ?? []) + staticPath
        var seen = Set<String>()
        env["PATH"] = entries.filter { seen.insert($0).inserted }.joined(separator: ":")
        if env["TERMINFO_DIRS"] == nil { env["TERMINFO_DIRS"] = bundledTerminfo }
        return env
    }
}
