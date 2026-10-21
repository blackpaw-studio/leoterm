import Foundation
import LeoKit
import OSLog

/// B2: turns this bundle into the owner of the daemon. Steps, in order:
/// copy tmux, refresh `~/.leo/app/bin/leo`, write the marker, register the
/// LaunchAgent, wait for hello. A failed register or hello rolls back to
/// "not managed" (unregister, remove the marker) and keeps the tmux copy.
struct LeoManagedSetup: Sendable {
    enum Step: String, Equatable, Sendable {
        case tmux, link, marker, register, hello
    }

    struct Failure: Error, Equatable, Sendable {
        let step: Step
        let message: String
    }

    enum Outcome: Equatable, Sendable {
        case ready(version: String)
        /// Registered, but the user must allow Leo in Login Items first.
        case awaitingApproval
        case failed(Failure)
    }

    /// What `prepare` left in place for `activate`.
    struct Prepared: Equatable, Sendable {
        let tmuxPath: URL
    }

    static let helloTimeout: TimeInterval = 20
    static let helloPollInterval: TimeInterval = 0.5

    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem
    let tmux: LeoTmuxInstaller
    let agent: any LeoLaunchAgentService
    let probe: any LeoDaemonProbing
    let clock: any LeoDaemonClock
    /// The validated login-shell `PATH` (A12), nil to use the static one.
    let loginPath: @Sendable () async -> String?
    let bundleID: String
    let label: String
    /// Only then is `~/.leo/app/bin/leo` repointed at this bundle (A14).
    let isInApplications: Bool

    func run(captured: [String: String]? = nil) async -> Outcome {
        switch await prepare() {
        case .failure(let failure): return .failed(failure)
        case .success(let prepared): return await activate(prepared, captured: captured)
        }
    }

    /// Steps 1–2, which register nothing: takeover (B3) runs them before the
    /// handover, so a failure there never leaves the CLI daemon stopped.
    func prepare() async -> Result<Prepared, Failure> {
        let tmuxPath: URL
        do {
            tmuxPath = try await tmux.installBundled()
        } catch {
            return .failure(Failure(step: .tmux, message: "\(error)"))
        }
        do {
            let link = try LeoSelfLink(paths: paths, fileSystem: fileSystem).refresh(isInApplications: isInApplications)
            if case .skipped(let reason) = link, let message = Self.message(for: reason) {
                return .failure(Failure(step: .link, message: message))
            }
        } catch {
            return .failure(Failure(step: .link, message: "\(error)"))
        }
        return .success(Prepared(tmuxPath: tmuxPath))
    }

    /// Steps 3–5. `captured` is the handover's env (B3); `restoreCLI` runs
    /// during a rollback, after `unregister()` and before the marker goes,
    /// since `handover --to-cli` needs the marker.
    func activate(_ prepared: Prepared, captured: [String: String]?, restoreCLI: (@Sendable () async -> Void)? = nil) async -> Outcome {
        let env = LeoDaemonEnvironment.merge(
            captured: captured, loginPath: await loginPath(), home: paths.home.path, bundledTerminfo: paths.bundledTerminfo.path
        )
        let marker = LeoManagedMarker(
            bundleID: bundleID, launchdLabel: label, selfPath: paths.selfLinkURL.path, tmuxPath: prepared.tmuxPath.path, env: env
        )
        do {
            try markerStore.write(marker)
        } catch {
            return .failed(Failure(step: .marker, message: "\(error)"))
        }
        do {
            try await agent.register()
        } catch {
            // macOS refuses the register while Login Items approval is pending.
            if agent.status() == .requiresApproval { return .awaitingApproval }
            return await rollBack(Failure(step: .register, message: "\(error)"), restoreCLI: restoreCLI)
        }
        if agent.status() == .requiresApproval { return .awaitingApproval }
        return await awaitHello(restoreCLI: restoreCLI)
    }

    /// Checked again when the app becomes active after the user visited Login Items.
    func resumeAfterApproval(restoreCLI: (@Sendable () async -> Void)? = nil) async -> Outcome {
        switch agent.status() {
        case .requiresApproval:
            return .awaitingApproval
        case .enabled:
            return await awaitHello(restoreCLI: restoreCLI)
        case .notRegistered, .notFound:
            return await rollBack(Failure(step: .register, message: "Leo’s daemon isn’t allowed in Login Items"), restoreCLI: restoreCLI)
        }
    }

    /// Polls hello until it answers or `helloTimeout` passes on `clock`.
    func waitForHello() async -> String? {
        let deadline = clock.now() + Self.nanoseconds(Self.helloTimeout)
        while true {
            if case .live(let version) = await probe.probe() { return version }
            let now = clock.now()
            guard now < deadline else { return nil }
            do {
                try await clock.sleep(until: min(now + Self.nanoseconds(Self.helloPollInterval), deadline))
            } catch {
                return nil
            }
        }
    }

    // MARK: private

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private var markerStore: LeoMarkerStore { LeoMarkerStore(paths: paths, fileSystem: fileSystem, bundleID: bundleID) }

    private func awaitHello(restoreCLI: (@Sendable () async -> Void)?) async -> Outcome {
        if let version = await waitForHello() { return .ready(version: version) }
        let message = "The daemon didn’t answer within \(Int(Self.helloTimeout)) seconds"
        return await rollBack(Failure(step: .hello, message: message), restoreCLI: restoreCLI)
    }

    /// Back to "not managed". Each step runs even if an earlier one failed:
    /// a registration left behind is recovered at the next launch (B1).
    private func rollBack(_ failure: Failure, restoreCLI: (@Sendable () async -> Void)?) async -> Outcome {
        Self.logger.error("managed setup failed at \(failure.step.rawValue, privacy: .public): \(failure.message, privacy: .public)")
        do {
            try await agent.unregister()
        } catch {
            Self.logger.error("rollback unregister failed: \(String(describing: error), privacy: .public)")
        }
        await restoreCLI?()
        do {
            try markerStore.remove()
        } catch {
            Self.logger.error("rollback marker removal failed: \(String(describing: error), privacy: .public)")
        }
        return .failed(failure)
    }

    private static func message(for reason: LeoSelfLink.SkipReason) -> String? {
        switch reason {
        case .notInApplications: nil
        case .helperMissing: "This copy of Leo has no bundled leo helper"
        case .occupied: "A file that isn’t Leo’s link is in the way at ~/.leo/app/bin/leo"
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
