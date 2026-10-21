import Foundation
import LeoKit
import OSLog

/// B2: turns this bundle into the owner of the daemon. Steps, in order:
/// copy tmux, refresh `~/.leo/app/bin/leo`, write the marker, register the
/// LaunchAgent, wait for hello. A failed register or hello rolls back to
/// "not managed" and keeps the tmux copy: after a takeover by handing the
/// daemon back to the CLI, otherwise by unregistering and removing the marker.
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
        /// Failed after a takeover, and `--to-cli` put the CLI daemon back.
        case handedBack(Failure)
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

    func run(captured: [String: String]? = nil, handBack: (@Sendable () async -> LeoHandoverRun)? = nil) async -> Outcome {
        switch await prepare() {
        case .failure(let failure): return .failed(failure)
        case .success(let prepared): return await activate(prepared, captured: captured, handBack: handBack)
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

    /// Takeover's check before the handover that step 3 can write the marker.
    func checkMarkerWritable() -> Failure? {
        do {
            try markerStore.checkWritable()
            return nil
        } catch {
            return Failure(step: .marker, message: "Leo can’t write \(paths.markerURL.path): \(error)")
        }
    }

    /// Steps 3–5. `captured` is the handover's env (B3); `handBack` is
    /// `handover --to-cli`, which a rollback after a takeover runs first.
    func activate(_ prepared: Prepared, captured: [String: String]?, handBack: (@Sendable () async -> LeoHandoverRun)? = nil) async -> Outcome {
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
            try await registerAgent()
        } catch {
            // macOS refuses the register while Login Items approval is pending.
            if agent.status() == .requiresApproval { return .awaitingApproval }
            return await rollBack(Failure(step: .register, message: "\(error)"), handBack: handBack)
        }
        if agent.status() == .requiresApproval { return .awaitingApproval }
        return await awaitHello(handBack: handBack)
    }

    /// Checked again when the app becomes active after the user visited Login Items.
    func resumeAfterApproval(handBack: (@Sendable () async -> LeoHandoverRun)? = nil) async -> Outcome {
        switch agent.status() {
        case .requiresApproval:
            return .awaitingApproval
        case .enabled:
            return await awaitHello(handBack: handBack)
        case .notRegistered, .notFound:
            return await rollBack(Failure(step: .register, message: "Leo’s daemon isn’t allowed in Login Items"), handBack: handBack)
        }
    }

    /// Polls hello until it answers or `helloTimeout` passes on `clock`.
    func waitForHello() async -> String? { await LeoHelloWait(probe: probe, clock: clock).version() }

    // MARK: private

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// "Already registered" says nothing about whether launchd runs the
    /// job, or with which marker: restart it unless approval is pending.
    private func registerAgent() async throws {
        do {
            try await agent.register()
        } catch let error as LeoLaunchAgentAlreadyRegistered {
            guard agent.status() != .requiresApproval else { throw error }
            try await agent.reRegister()
        }
    }

    private var markerStore: LeoMarkerStore { LeoMarkerStore(paths: paths, fileSystem: fileSystem, bundleID: bundleID) }

    private func awaitHello(handBack: (@Sendable () async -> LeoHandoverRun)?) async -> Outcome {
        if let version = await waitForHello() { return .ready(version: version) }
        let message = "The daemon didn’t answer within \(Int(Self.helloTimeout)) seconds"
        return await rollBack(Failure(step: .hello, message: message), handBack: handBack)
    }

    /// Back to "not managed", keeping whatever recovery needs if that fails.
    private func rollBack(_ failure: Failure, handBack: (@Sendable () async -> LeoHandoverRun)?) async -> Outcome {
        Self.logger.error("managed setup failed at \(failure.step.rawValue, privacy: .public): \(failure.message, privacy: .public)")
        guard let handBack else {
            await unregisterAndRemoveMarker()
            return .failed(failure)
        }
        return await handBackToCLI(handBack) ? .handedBack(failure) : .failed(failure)
    }

    /// `--to-cli` needs the marker and moves it aside itself; it boots the
    /// app's job out, so the app unregisters only once leo says it did. On
    /// anything else the marker and registration stay for the next launch.
    /// True once leo says the CLI daemon is back.
    private func handBackToCLI(_ handBack: @Sendable () async -> LeoHandoverRun) async -> Bool {
        switch await handBack() {
        case .succeeded(let result) where result.managedStopped:
            do {
                try await agent.unregister()
            } catch {
                Self.logger.error("rollback unregister failed: \(String(describing: error), privacy: .public)")
            }
            return true
        case .succeeded:
            Self.logger.error("handover --to-cli succeeded without stopping the app's job; keeping its registration")
            return true
        case .failed(let failure):
            Self.logger.error("handover --to-cli failed: \(failure.error, privacy: .public) \(failure.summary, privacy: .public)")
            // leo booted the app's job out and can't restore the CLI: keep the app's daemon running.
            guard failure.managedStopped == true else { return false }
            do {
                _ = try await agent.restartStoppedJob(hello: LeoHelloWait(probe: probe, clock: clock))
            } catch {
                Self.logger.error("restarting Leo's daemon failed: \(String(describing: error), privacy: .public)")
            }
            return false
        case .malformed(let message):
            Self.logger.error("handover --to-cli: \(message, privacy: .public)")
            return false
        }
    }

    /// A fresh install: each step runs even if the first failed, since a
    /// registration left behind is recovered at the next launch (B1).
    private func unregisterAndRemoveMarker() async {
        do {
            try await agent.unregister()
        } catch {
            Self.logger.error("rollback unregister failed: \(String(describing: error), privacy: .public)")
        }
        do {
            try markerStore.remove()
        } catch {
            Self.logger.error("rollback marker removal failed: \(String(describing: error), privacy: .public)")
        }
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
