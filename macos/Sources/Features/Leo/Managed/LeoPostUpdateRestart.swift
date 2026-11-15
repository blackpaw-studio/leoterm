import Foundation

/// B6: after a Sparkle update the bundled leo differs from the daemon still
/// running the old one. Copy the new tmux beside the old (never replacing a
/// version dir a `-L leo` server may use), point the marker at it, then
/// `service restart --graceful` (a non-interactive drain).
struct LeoPostUpdateRestart: Sendable {
    enum Outcome: Equatable, Sendable {
        case restarted(version: String)
        /// The daemon answered with another version, or (nil) not at all.
        case stillDifferent(bundled: String, running: String?)
        case notRegistered(message: String)
        /// Agents stayed busy past the drain; the old daemon still runs.
        case drainTimedOut
        case failed(message: String)
    }

    /// `leo service restart --json`'s success.
    struct Restarted: Decodable, Equatable, Sendable {
        let drained: Bool?
        let restarted: Bool?
    }

    static let codeNotRegistered = "not_registered"
    static let codeDrainTimeout = "drain_timeout"
    static let versionPrefix = "leo "
    static let versionTimeout: TimeInterval = 10

    let runner: any LeoProcessRunning
    let bundledLeo: String
    let tmux: LeoTmuxInstaller
    let markerStore: LeoMarkerStore
    let probe: any LeoDaemonProbing
    let clock: any LeoDaemonClock

    /// Plain string inequality, not an ordering: a downgrade restarts too.
    static func shouldRestart(managedByUs: Bool, bundled: String, running: String, alreadyTriedPair: Bool) -> Bool {
        managedByUs && bundled != running && !alreadyTriedPair
    }

    /// `Helpers/leo version` minus its `leo ` prefix; nil when it can't say.
    func bundledVersion() async -> String? {
        guard let result = try? await runner.run(executable: bundledLeo, arguments: ["version"], timeout: Self.versionTimeout),
              result.status == 0 else { return nil }
        let output = (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let version = output.hasPrefix(Self.versionPrefix) ? String(output.dropFirst(Self.versionPrefix.count)) : output
        return version.isEmpty ? nil : version
    }

    func restart(bundled: String) async -> Outcome {
        guard case .ours(let marker) = markerStore.read() else {
            return .failed(message: "Leo’s marker at ~/.leo/state/managed.json is missing or not this app’s")
        }
        do {
            try await pointMarker(marker, at: tmux.installBundled())
        } catch {
            return .failed(message: "Couldn’t install the updated tmux: \(error)")
        }
        let result: LeoProcessResult
        do {
            result = try await runner.run(executable: bundledLeo, arguments: Self.arguments, timeout: LeoHandover.timeout)
        } catch {
            return .failed(message: "leo service restart didn’t run: \(error)")
        }
        switch LeoJSONAnswer<Restarted>(result) {
        case .succeeded: return await awaitVersion(bundled)
        case .failed(let failure): return Self.outcome(for: failure)
        case .malformed(let message): return .failed(message: message)
        }
    }

    // MARK: private

    private static let arguments = ["service", "restart", "--graceful", "--json"]

    private static func outcome(for failure: LeoJSONFailure) -> Outcome {
        switch failure.error {
        case codeNotRegistered: .notRegistered(message: failure.message ?? "Leo’s LaunchAgent isn’t loaded")
        case codeDrainTimeout: .drainTimedOut
        default: .failed(message: failure.summary)
        }
    }

    private func pointMarker(_ marker: LeoManagedMarker, at tmuxPath: URL) throws {
        guard marker.tmuxPath != tmuxPath.path else { return }
        try markerStore.write(LeoManagedMarker(
            bundleID: marker.bundleID, launchdLabel: marker.launchdLabel, selfPath: marker.selfPath,
            tmuxPath: tmuxPath.path, env: marker.env
        ))
    }

    /// Polls hello until it reports `bundled`, past an old daemon still
    /// answering, for up to the setup's hello timeout.
    private func awaitVersion(_ bundled: String) async -> Outcome {
        let deadline = clock.now() + Self.nanoseconds(LeoManagedSetup.helloTimeout)
        var lastSeen: String?
        while true {
            if case .live(let version) = await probe.probe() {
                if version == bundled { return .restarted(version: version) }
                lastSeen = version
            }
            let now = clock.now()
            guard now < deadline else { break }
            do {
                try await clock.sleep(until: min(now + Self.nanoseconds(LeoManagedSetup.helloPollInterval), deadline))
            } catch {
                break
            }
        }
        return .stillDifferent(bundled: bundled, running: lastSeen)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
