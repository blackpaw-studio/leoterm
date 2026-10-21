import Foundation
import OSLog

/// The alerts the managed flow shows; the app's are `NSAlert`s.
@MainActor protocol LeoManagedPresenting: AnyObject {
    func confirmReleaseToCLI() async -> Bool
    func showMoveBackAlert()
    func showError(title: String, message: String)
}

/// Everything the managed flow touches, as seams.
struct LeoManagedDependencies: Sendable {
    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem
    let runner: any LeoProcessRunning
    let agent: any LeoLaunchAgentService
    let probe: any LeoDaemonProbing
    let clock: any LeoDaemonClock
    let loginPath: @Sendable () async -> String?
    let makeToken: @Sendable () -> String
    let bundleID: String
    let label: String
    let buildKind: LeoBuildKind
    /// The process environment, for `LEO_MANAGED_DEBUG`.
    let environment: [String: String]
}

/// B5: the launch-time location → probe → decide → execute step, and the
/// user's managed-daemon actions after it (takeover, approval, release).
@MainActor final class LeoManagedStartup {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private(set) var status: LeoManagedStatus = .inactive { didSet { publish() } }
    private var notice: LeoManagedNotice? { didSet { publish() } }
    /// Every change, for the sidebar.
    var onChange: (LeoManagedPresentation) -> Void = { _ in }
    /// The A9 mover and the CLI "Start daemon" command, owned by the app.
    var moveToApplicationsRequested: () -> Void = {}
    var startCLIDaemonRequested: () -> Void = {}

    var presentation: LeoManagedPresentation { LeoManagedPresentation(status: status, notice: notice) }
    var summary: LeoManagedSummary {
        switch status {
        case .managed(let version): LeoManagedSummary(isManaged: true, version: version)
        case .updating: LeoManagedSummary(isManaged: true, version: nil)
        default: LeoManagedSummary(isManaged: false, version: nil)
        }
    }

    private let dependencies: LeoManagedDependencies
    private let takeoverStore: LeoTakeoverStore
    private let location: () async -> LeoAppLocation?
    private let presenter: any LeoManagedPresenting
    private var resolvedLocation: LeoAppLocation?
    /// B6: each bundled → running pair is restarted at most once per launch.
    private var triedRestarts: Set<[String]> = []
    /// Approval is pending after a takeover: a rollback must hand back to the CLI.
    private var approvalFollowsTakeover = false
    /// One managed operation at a time; a second click while one runs is ignored.
    private var isBusy = false

    init(
        dependencies: LeoManagedDependencies, takeoverStore: LeoTakeoverStore,
        location: @escaping () async -> LeoAppLocation?, presenter: any LeoManagedPresenting
    ) {
        self.dependencies = dependencies
        self.takeoverStore = takeoverStore
        self.location = location
        self.presenter = presenter
    }

    /// Waits for the A9 location check; nil means the app is moving itself and
    /// quitting. A build that manages nothing doesn't wait (D4).
    func run() async {
        guard isManagementEnabled, let location = await location() else { return }
        resolvedLocation = location
        await exclusively { await self.decideAndExecute() }
    }

    /// B6, off the launch path (a graceful drain can take minutes): restart
    /// a managed daemon whose version isn't the bundled one.
    func restartIfUpdated() async {
        guard case .managed(let running?) = status, markerStore.read().ours != nil else { return }
        await exclusively { await self.restartAfterUpdate(running: running) }
    }

    func applicationDidBecomeActive() async {
        guard status == .awaitingApproval else { return }
        await exclusively {
            let restoreCLI = self.approvalFollowsTakeover ? self.handBackToCLI : nil
            self.apply(await self.setup.resumeAfterApproval(restoreCLI: restoreCLI))
        }
    }

    func perform(_ action: LeoManagedBannerAction) async {
        switch action {
        case .takeOver: await exclusively { await self.takeOver() }
        case .notNow: declineTakeover()
        case .openLoginItems: dependencies.agent.openLoginItemsSettings()
        case .moveToApplications: moveToApplicationsRequested()
        case .retry: await exclusively { await self.decideAndExecute() }
        case .dismiss: notice = nil
        }
    }

    func perform(_ action: LeoDaemonStartAction) async {
        switch action {
        case .setUp: await perform(.retry)
        case .allowInLoginItems: await perform(.openLoginItems)
        case .moveToApplications: moveToApplicationsRequested()
        case .startCLIDaemon: startCLIDaemonRequested()
        }
    }

    /// B4, from the menu bar extra.
    func releaseToCLI() async {
        guard summary.isManaged else { return }
        await exclusively {
            let presenter = self.presenter
            let outcome = await self.release.run(confirm: { await presenter.confirmReleaseToCLI() })
            switch outcome {
            case .declined:
                break
            case .released(let warnings):
                warnings.forEach { Self.logger.log("release to CLI: \($0, privacy: .public)") }
                self.takeoverStore.clear()
                self.status = .usingCLI(offerTakeover: false, isRunning: true)
            case .failed(let message, _):
                presenter.showError(title: "Leo couldn’t hand the daemon back to the CLI", message: message)
            }
        }
    }

    // MARK: decide and execute

    private var isManagementEnabled: Bool {
        LeoFirstRun.isManagementEnabled(buildKind: dependencies.buildKind, environment: dependencies.environment)
    }

    private func decideAndExecute(afterOrphanRecovery: Bool = false) async {
        guard let location = resolvedLocation else { return }
        // A Debug build never even asks SMAppService (D4).
        guard isManagementEnabled else {
            status = .inactive
            return
        }
        let inputs = await gatherInputs(location: location)
        let action = LeoFirstRun.decide(inputs)
        // Unregistered once already: don't loop on a registration that stays.
        if afterOrphanRecovery, action == .recoverOrphanRegistration {
            status = .failed(message: "Leo’s login item is still registered. \(Self.loginItemsAdvice)")
            return
        }
        await execute(action, inputs: inputs)
    }

    private func gatherInputs(location: LeoAppLocation) async -> LeoFirstRunInputs {
        let probe = await dependencies.probe.probe()
        let fileSystem = dependencies.fileSystem
        let paths = dependencies.paths
        return LeoFirstRunInputs(
            location: location,
            probe: probe,
            marker: markerStore.read(),
            existing: LeoFirstRun.detectExisting(probe: probe, paths: paths, fileSystem: fileSystem),
            agentStatus: dependencies.agent.status(),
            takeover: takeoverStore.answer,
            buildKind: dependencies.buildKind,
            managedDebug: dependencies.environment[LeoFirstRun.managedDebugKey] == "1",
            hasBundledHelpers: fileSystem.kind(at: paths.bundledLeo) == .file && fileSystem.kind(at: paths.bundledTmux) == .file
        )
    }

    private func execute(_ action: LeoFirstRunAction, inputs: LeoFirstRunInputs) async {
        switch action {
        case .observeOnly:
            status = .inactive
        case .blockMove(let isManaged):
            status = .moveRequired(isManaged: isManaged)
            if isManaged { presenter.showMoveBackAlert() }
        case .useLive(let offerTakeover):
            status = .usingCLI(offerTakeover: offerTakeover, isRunning: inputs.probe.version != nil)
        case .install:
            await runSetup(captured: nil)
        case .ensureManaged(let refreshLink, let register):
            if refreshLink { refreshSelfLink() }
            if register {
                await runSetup(captured: inputs.marker.ours?.env)
            } else {
                await awaitManagedHello(probe: inputs.probe)
            }
        case .awaitApproval:
            approvalFollowsTakeover = false
            status = .awaitingApproval
        case .repair(.invalidMarker(let detail)):
            Self.logger.error("rewriting an invalid managed.json: \(detail, privacy: .public)")
            await runSetup(captured: nil)
        case .repair(.bundleIncomplete):
            status = .failed(
                message: "This copy of Leo is missing the daemon it bundles. Download Leo again and replace the copy in Applications."
            )
        case .recoverOrphanRegistration:
            await recoverOrphanRegistration()
        }
    }

    private static let loginItemsAdvice = "Turn Leo off in System Settings ▸ General ▸ Login Items, then Try Again."

    /// Registered with no marker: a crash between Release to CLI's handover
    /// and its `unregister()`. Finish it, then decide afresh.
    private func recoverOrphanRegistration() async {
        do {
            try await dependencies.agent.unregister()
        } catch {
            Self.logger.error("unregistering a leftover LaunchAgent failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: "Leo couldn’t remove a leftover login item. \(Self.loginItemsAdvice)")
            return
        }
        await decideAndExecute(afterOrphanRecovery: true)
    }

    private func runSetup(captured: [String: String]?) async {
        status = .settingUp
        apply(await setup.run(captured: captured))
    }

    private func awaitManagedHello(probe: LeoDaemonProbeResult) async {
        if let version = probe.version {
            status = .managed(version: version)
        } else if let version = await setup.waitForHello() {
            status = .managed(version: version)
        } else {
            status = .failed(message: "Leo’s daemon isn’t answering. See ~/.leo/state/service.log, or run leo doctor.")
        }
    }

    private func apply(_ outcome: LeoManagedSetup.Outcome) {
        switch outcome {
        case .ready(let version): status = .managed(version: version)
        case .awaitingApproval: status = .awaitingApproval
        case .failed(let failure): status = .failed(message: failure.message)
        }
    }

    private func refreshSelfLink() {
        do {
            _ = try LeoSelfLink(paths: dependencies.paths, fileSystem: dependencies.fileSystem).refresh(isInApplications: true)
        } catch {
            Self.logger.error("refreshing ~/.leo/app/bin/leo failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: after a Sparkle update

    private func restartAfterUpdate(running: String) async {
        let restarter = postUpdateRestart
        guard let bundled = await restarter.bundledVersion(),
              LeoPostUpdateRestart.shouldRestart(
                  managedByUs: true, bundled: bundled, running: running, alreadyTriedPair: triedRestarts.contains([bundled, running])
              ) else { return }
        triedRestarts.insert([bundled, running])
        status = .updating(to: bundled)
        let outcome = await restarter.restart(bundled: bundled)
        let doctor = "Run “leo doctor” in Terminal to see why."
        switch outcome {
        case .restarted(let version):
            status = .managed(version: version)
        case .stillDifferent(_, let now):
            status = .managed(version: now ?? running)
            let answer = now.map { "still reports \($0)" } ?? "didn’t answer"
            notice = LeoManagedNotice(
                title: "Leo’s daemon didn’t update", message: "It \(answer) after restarting; Leo includes \(bundled). \(doctor)"
            )
        case .drainTimedOut:
            status = .managed(version: running)
            notice = LeoManagedNotice(
                title: "Leo’s daemon is still on \(running)",
                message: "Agents were busy, so it wasn’t restarted. Choose Restart Daemon in the menu bar when they’re done."
            )
        case .notRegistered(let message), .failed(let message):
            status = .managed(version: running)
            let sentence = message.hasSuffix(".") ? message : message + "."
            notice = LeoManagedNotice(title: "Leo couldn’t update its daemon", message: "\(sentence) \(doctor)")
        }
    }

    // MARK: takeover

    private func takeOver() async {
        guard case .usingCLI(offerTakeover: true, let wasRunning) = status else { return }
        status = .settingUp
        let outcome = await LeoTakeover(
            handover: handover, setup: setup, runner: dependencies.runner, loginPath: dependencies.loginPath, label: dependencies.label
        ).run()
        if let answer = LeoTakeoverAnswer.remembered(after: outcome) { takeoverStore.answer = answer }
        switch outcome {
        case .managed(let version, let warnings):
            warnings.forEach { Self.logger.log("takeover: \($0, privacy: .public)") }
            status = .managed(version: version)
        case .awaitingApproval:
            approvalFollowsTakeover = true
            status = .awaitingApproval
        case .cannotTakeOver:
            status = .usingCLI(offerTakeover: false, isRunning: wasRunning)
            notice = LeoManagedNotice(
                title: "Leo can’t take over this daemon",
                message: "It wasn’t started by launchd. Stop it (run “leo service stop”, or quit the terminal running “leo service start”), then quit and reopen Leo."
            )
        case .preparationFailed(let failure):
            status = .usingCLI(offerTakeover: false, isRunning: wasRunning)
            presenter.showError(title: "Leo couldn’t take over the daemon", message: failure.message)
        case .handoverFailed(_, let message, let rolledBack):
            status = .usingCLI(offerTakeover: false, isRunning: wasRunning && rolledBack != false)
            let restart = rolledBack == false ? " Start your daemon again with “leo service start --daemon”." : ""
            presenter.showError(title: "Leo couldn’t take over the daemon", message: message + restart)
        case .setupFailed(let failure, let cliRestored):
            status = .usingCLI(offerTakeover: false, isRunning: cliRestored)
            let next = cliRestored ? " Your CLI daemon is running again." : " Start your daemon with “leo service start --daemon”."
            presenter.showError(title: "Leo couldn’t start its daemon", message: failure.message + next)
        }
    }

    private func declineTakeover() {
        takeoverStore.answer = .declined
        guard case .usingCLI(_, let isRunning) = status else { return }
        status = .usingCLI(offerTakeover: false, isRunning: isRunning)
    }

    // MARK: seams

    private var markerStore: LeoMarkerStore {
        LeoMarkerStore(paths: dependencies.paths, fileSystem: dependencies.fileSystem, bundleID: dependencies.bundleID)
    }

    private var handover: LeoHandover { LeoHandover(runner: dependencies.runner, bundledLeo: dependencies.paths.bundledLeo.path) }

    private var handBackToCLI: @Sendable () async -> Void {
        let handover = handover
        return { _ = await handover.toCLI() }
    }

    private var release: LeoReleaseToCLI {
        LeoReleaseToCLI(handover: handover, agent: dependencies.agent, paths: dependencies.paths, fileSystem: dependencies.fileSystem)
    }

    private var postUpdateRestart: LeoPostUpdateRestart {
        let d = dependencies
        return LeoPostUpdateRestart(
            runner: d.runner, bundledLeo: d.paths.bundledLeo.path,
            tmux: LeoTmuxInstaller(paths: d.paths, fileSystem: d.fileSystem, runner: d.runner, makeToken: d.makeToken),
            markerStore: markerStore, probe: d.probe, clock: d.clock
        )
    }

    private var setup: LeoManagedSetup {
        let d = dependencies
        return LeoManagedSetup(
            paths: d.paths, fileSystem: d.fileSystem,
            tmux: LeoTmuxInstaller(paths: d.paths, fileSystem: d.fileSystem, runner: d.runner, makeToken: d.makeToken),
            agent: d.agent, probe: d.probe, clock: d.clock, loginPath: d.loginPath,
            bundleID: d.bundleID, label: d.label, isInApplications: resolvedLocation == .inApplications
        )
    }

    private func exclusively(_ body: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await body()
    }

    private func publish() { onChange(presentation) }
}

extension LeoDaemonProbeResult {
    var version: String? {
        guard case .live(let version) = self else { return nil }
        return version
    }
}

extension LeoMarkerState {
    var ours: LeoManagedMarker? {
        guard case .ours(let marker) = self else { return nil }
        return marker
    }
}
