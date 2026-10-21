import Foundation

enum LeoTakeoverOutcome: Equatable, Sendable {
    case managed(version: String, warnings: [String])
    /// Handed over; the app's agent waits for Login Items approval.
    case awaitingApproval(warnings: [String])
    /// `no_launchd_job`: keep using the live daemon; tell the user how to stop it.
    case cannotTakeOver
    /// Nothing was handed over.
    case preparationFailed(LeoManagedSetup.Failure)
    /// leo refused or failed. `rolledBack` false means the CLI daemon may be
    /// down (point at `leo service start --daemon`); nil means unknown.
    case handoverFailed(step: String?, message: String, rolledBack: Bool?)
    /// The handover succeeded but the app's own setup didn't; `--to-cli` ran.
    case setupFailed(LeoManagedSetup.Failure, cliRestored: Bool)
}

extension LeoTakeoverAnswer {
    /// What to remember after a takeover attempt; nil leaves the answer as it was.
    static func remembered(after outcome: LeoTakeoverOutcome) -> LeoTakeoverAnswer? {
        outcome == .cannotTakeOver ? .unavailable : nil
    }
}

/// The one-time offer's answer, in `UserDefaults.ghostty`.
struct LeoTakeoverStore {
    static let key = "leo.managed.takeoverAnswer"

    let defaults: UserDefaults

    var answer: LeoTakeoverAnswer {
        get { defaults.string(forKey: Self.key).flatMap(LeoTakeoverAnswer.init(rawValue:)) ?? .notAsked }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// B3: moves a CLI-installed daemon under the app. The setup's preparation
/// (tmux, link) runs first, then the running `-L leo` server's tmux version
/// is preserved, then leo hands over; only after `ok` does the app write
/// its marker and register.
struct LeoTakeover: Sendable {
    static let tmuxQueryTimeout: TimeInterval = 10

    let handover: LeoHandover
    let setup: LeoManagedSetup
    /// Runs the CLI's tmux for the running server's version.
    let runner: any LeoProcessRunning
    let loginPath: @Sendable () async -> String?
    let label: String

    func run() async -> LeoTakeoverOutcome {
        let prepared: LeoManagedSetup.Prepared
        switch await setup.prepare() {
        case .failure(let failure): return .preparationFailed(failure)
        case .success(let value): prepared = value
        }
        let tmuxWarnings = await preserveRunningTmux()

        let result: LeoHandoverResult
        switch await handover.toApp(label: label) {
        case .succeeded(let value):
            result = value
        case .failed(let failed) where failed.error == LeoHandover.codeNoLaunchdJob:
            return .cannotTakeOver
        case .failed(let failed):
            return .handoverFailed(step: failed.step, message: failed.summary, rolledBack: failed.rolledBack)
        case .malformed(let message):
            return .handoverFailed(step: nil, message: message, rolledBack: nil)
        }

        let warnings = tmuxWarnings + result.warnings
        let restored = LeoFlag()
        let handover = handover
        let outcome = await setup.activate(prepared, captured: result.env) {
            if case .succeeded = await handover.toCLI() { restored.set() }
        }
        switch outcome {
        case .ready(let version): return .managed(version: version, warnings: warnings)
        case .awaitingApproval: return .awaitingApproval(warnings: warnings)
        case .failed(let failure): return .setupFailed(failure, cliRestored: restored.isSet)
        }
    }

    // MARK: the running server's tmux

    /// leo's version guard needs `~/.leo/app/tmux/<server version>/tmux` to
    /// keep attaching to a server the CLI daemon started (Homebrew's 3.6a,
    /// say, while the bundle ships 3.6b). Copies the CLI's own tmux there.
    private func preserveRunningTmux() async -> [String] {
        let candidates = await cliTmuxCandidates()
        guard let client = candidates.first,
              let version = await serverVersion(using: client),
              let destination = setup.paths.tmuxURL(version: version),
              setup.fileSystem.kind(at: destination) == .absent else { return [] }
        for candidate in candidates {
            guard (try? await setup.tmux.version(of: candidate.path)) == version else { continue }
            do {
                _ = try setup.tmux.install(resolvingSymlinks(candidate), version: version)
                return []
            } catch {
                return ["Couldn’t keep tmux \(version) for the running sessions: \(error)"]
            }
        }
        return ["No tmux \(version) binary was found for the running sessions; attaching to them may fail until they restart."]
    }

    private func serverVersion(using client: URL) async -> String? {
        let arguments = ["-L", "leo", "display", "-p", "#{version}"]
        guard let result = try? await runner.run(executable: client.path, arguments: arguments, timeout: Self.tmuxQueryTimeout),
              result.status == 0 else { return nil }
        let version = (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// The CLI daemon resolves `tmux` on its LaunchAgent's `PATH`; then the
    /// login and static paths, for a daemon started some other way.
    private func cliTmuxCandidates() async -> [URL] {
        let directories = [cliPlistPath(), await loginPath()].compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) } + LeoDaemonEnvironment.staticPath
        var seen = Set<String>()
        return directories
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("tmux") }
            .filter { setup.fileSystem.kind(at: $0) != .absent }
    }

    private func cliPlistPath() -> String? {
        guard let data = try? setup.fileSystem.read(setup.paths.cliLaunchAgentPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let environment = plist["EnvironmentVariables"] as? [String: Any] else { return nil }
        return environment["PATH"] as? String
    }

    /// Homebrew's `bin/tmux` is a relative symlink into its Cellar: copy the binary, not the link.
    private func resolvingSymlinks(_ url: URL) -> URL {
        var current = url
        for _ in 0..<Self.maxSymlinkHops {
            guard case .symlink(let target) = setup.fileSystem.kind(at: current) else { break }
            let next = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : current.deletingLastPathComponent().appendingPathComponent(target)
            current = next.standardizedFileURL
        }
        return current
    }

    private static let maxSymlinkHops = 8
}

/// A set-once flag a `@Sendable` rollback closure can raise.
private final class LeoFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
