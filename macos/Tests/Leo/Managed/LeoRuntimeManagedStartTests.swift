import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B5: launch-time location → probe → decide → execute, and what the
/// sidebar offers for each outcome. Every seam is a fake.
@MainActor struct LeoRuntimeManagedStartTests {
    final class Presenter: LeoManagedPresenting {
        var confirmsRelease = true
        private(set) var moveBackAlerts = 0
        private(set) var errors: [String] = []

        func confirmReleaseToCLI() async -> Bool { confirmsRelease }
        func showMoveBackAlert() { moveBackAlerts += 1 }
        func showError(title: String, message _: String) { errors.append(title) }
    }

    @MainActor struct Rig {
        let base = LeoManagedSetupTests.Rig()
        let defaults = LeoInMemoryDefaults()
        let presenter = Presenter()
        let locationQueries = Recorded()
        var log: LeoManagedEventLog { base.log }
        var store: LeoTakeoverStore { LeoTakeoverStore(defaults: defaults) }

        init() {
            base.runner.on(LeoHandoverTests.toApp, .exit(0, stdout: LeoHandoverTests.okJSON))
            base.runner.on(LeoHandoverTests.toCLI, .exit(0, stdout: LeoHandoverTests.toCLIOKJSON))
            base.runner.on([LeoHandoverTests.bundled, "version"], .exit(0, stdout: "leo 0.57.0\n"))
        }

        func startup(
            buildKind: LeoBuildKind = .release, environment: [String: String] = [:], location: LeoAppLocation? = .inApplications
        ) -> LeoManagedStartup {
            let dependencies = LeoManagedDependencies(
                paths: LeoManagedSetupTests.paths, fileSystem: base.fileSystem, runner: base.runner, agent: base.agent,
                probe: base.probe, clock: base.clock, loginPath: { "/usr/bin:/bin" }, makeToken: base.tokens.next,
                bundleID: LeoManagedSetupTests.bundleID, label: LeoManagedSetupTests.label,
                buildKind: buildKind, environment: environment
            )
            return LeoManagedStartup(
                dependencies: dependencies, takeoverStore: store,
                location: { [locationQueries] in
                    locationQueries.count += 1
                    return location
                },
                presenter: presenter
            )
        }

        func writeOurMarker() throws {
            let marker = LeoManagedMarker(
                bundleID: LeoManagedSetupTests.bundleID, launchdLabel: LeoManagedSetupTests.label,
                selfPath: LeoManagedSetupTests.link, tmuxPath: LeoManagedSetupTests.tmuxCopy, env: ["PATH": "/x"]
            )
            base.fileSystem.addFile(LeoManagedSetupTests.marker, try marker.encoded(), mode: 0o600)
        }

        func count(_ event: LeoManagedEvent) -> Int { log.events.filter { $0 == event }.count }
    }

    // MARK: the plan's three rows

    @Test func aFreshInstallRunsInstallOnce() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered, .enabled)

        let startup = rig.startup()
        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(rig.count(.run([LeoManagedSetupTests.bundledTmux, "-V"])) == 1)
        #expect(rig.count(.agent("register")) == 1)
        #expect(startup.summary == LeoManagedSummary(isManaged: true, version: "0.57.0"))
    }

    @Test func aLiveCLIDaemonShowsTheOfferAndWritesNothing() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))

        let startup = rig.startup()
        await startup.run()

        #expect(startup.status == .usingCLI(offerTakeover: true, isRunning: true))
        #expect(startup.presentation.banner?.actions == [.takeOver, .notNow])
        #expect(rig.log.events.isEmpty)
        #expect(rig.store.answer == .notAsked)
    }

    @Test func aDebugBuildMakesNoLaunchAgentCalls() async {
        let rig = Rig()

        let startup = rig.startup(buildKind: .debug, location: .exempt)
        await startup.run()

        #expect(startup.status == .inactive)
        #expect(rig.base.agent.statusReads == 0)
        #expect(rig.log.events.isEmpty)
        #expect(rig.base.probe.probes == 0)
        // Nor does it hold host startup behind the location check.
        #expect(rig.locationQueries.count == 0)
    }

    // MARK: more rows

    @Test func aDebugBuildWithTheOptInInstallsButLeavesTheReleaseLinkAlone() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered, .enabled)

        let startup = rig.startup(buildKind: .debug, environment: ["LEO_MANAGED_DEBUG": "1"], location: .exempt)
        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(!rig.log.events.contains { if case .fs(.symlink) = $0 { true } else { false } })
    }

    @Test func nothingHappensWhileTheAppIsMovingItself() async {
        let rig = Rig()

        let startup = rig.startup(location: nil)
        await startup.run()

        #expect(startup.status == .inactive)
        #expect(rig.base.agent.statusReads == 0)
    }

    @Test func aManagedDaemonRefreshesTheLinkAndReportsItsVersion() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))

        let startup = rig.startup()
        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(rig.log.events.contains(.fs(.rename("/home/test/.leo/app/bin/.leo.t1.tmp", LeoManagedSetupTests.link))))
        #expect(!rig.log.events.contains(.agent("register")))
    }

    @Test func aManagedDaemonThatNeverAnswersIsAFailureWithRetry() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.absent)

        let startup = rig.startup()
        await startup.run()

        guard case .failed = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }
        #expect(startup.presentation.startAction == .setUp)
        #expect(!rig.log.events.contains(.agent("unregister")))
    }

    @Test func approvalIsResumedWhenTheAppBecomesActive() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.agent.script(status: .requiresApproval)

        let startup = rig.startup()
        await startup.run()
        #expect(startup.status == .awaitingApproval)
        #expect(startup.presentation.startAction == .allowInLoginItems)

        rig.base.agent.script(status: .enabled)
        await startup.applicationDidBecomeActive()

        #expect(startup.status == .managed(version: "0.57.0"))
    }

    // MARK: a takeover pending approval survives a relaunch

    static let plistBackup = "/home/test/Library/LaunchAgents/com.blackpaw.leo.plist.handed-over"

    /// Relaunched while Login Items approval is pending after a takeover: the
    /// CLI plist is still leo's `.handed-over` backup, so a denial hands back.
    @Test func aDeniedApprovalAfterARelaunchHandsTheDaemonBackToTheCLI() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.fileSystem.addFile(Self.plistBackup, "<plist/>")
        rig.base.agent.script(status: .requiresApproval)
        let startup = rig.startup()
        await startup.run()
        #expect(startup.status == .awaitingApproval)

        rig.base.agent.script(status: .notRegistered)
        await startup.applicationDidBecomeActive()

        #expect(Array(rig.log.events.suffix(2)) == [.run(LeoHandoverTests.toCLI), .agent("unregister")])
        #expect(!rig.log.events.contains(.fs(.remove(LeoManagedSetupTests.marker))))
    }

    @Test func aDeniedApprovalWithoutAHandoverRollsBackLocally() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.agent.script(status: .requiresApproval)
        let startup = rig.startup()
        await startup.run()

        rig.base.agent.script(status: .notRegistered)
        await startup.applicationDidBecomeActive()

        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toCLI)))
        #expect(Array(rig.log.events.suffix(2)) == [.agent("unregister"), .fs(.remove(LeoManagedSetupTests.marker))])
    }

    /// Managed after a takeover but unregistered (say, removed in Login
    /// Items): a failed re-register hands back too, never strands the CLI.
    @Test func aFailedReRegisterAfterATakeoverHandsTheDaemonBackToTheCLI() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.fileSystem.addFile(Self.plistBackup, "<plist/>")
        rig.base.agent.script(status: .notRegistered)
        rig.base.agent.failNextRegister()

        let startup = rig.startup()
        await startup.run()

        #expect(Array(rig.log.events.suffix(3)) == [.agent("register"), .run(LeoHandoverTests.toCLI), .agent("unregister")])
    }

    @Test func becomingActiveOutsideApprovalDoesNothing() async {
        let rig = Rig()
        let startup = rig.startup(buildKind: .debug, location: .exempt)
        await startup.run()

        await startup.applicationDidBecomeActive()

        #expect(rig.base.agent.statusReads == 0)
    }

    // MARK: the takeover offer

    @Test func acceptingTheOfferTakesTheDaemonOver() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        let startup = rig.startup()
        await startup.run()

        rig.base.agent.script(status: .enabled)
        rig.base.probe.script(.live(version: "0.57.0"))
        await startup.perform(.takeOver)

        #expect(rig.count(.run(LeoHandoverTests.toApp)) == 1)
        #expect(startup.status == .managed(version: "0.57.0"))
    }

    @Test func notNowIsRememberedAndHidesTheOffer() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        let startup = rig.startup()
        await startup.run()

        await startup.perform(.notNow)

        #expect(rig.store.answer == .declined)
        #expect(startup.status == .usingCLI(offerTakeover: false, isRunning: true))
        #expect(startup.presentation.banner == nil)
        #expect(rig.log.events.isEmpty)
    }

    @Test func noLaunchdJobIsRememberedAndExplained() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        let json = #"{"ok":false,"step":"preflight","error":"no_launchd_job"}"#
        rig.base.runner.on(LeoHandoverTests.toApp, .exit(1, stdout: json))
        let startup = rig.startup()
        await startup.run()

        await startup.perform(.takeOver)

        #expect(rig.store.answer == .unavailable)
        #expect(startup.status == .usingCLI(offerTakeover: false, isRunning: true))
        #expect(startup.presentation.banner?.actions == [.dismiss])

        await startup.perform(.dismiss)
        #expect(startup.presentation.banner == nil)
    }

    // MARK: release to CLI

    @Test func releasingClearsTheAnswerAndLeavesTheCLIInCharge() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))
        rig.store.answer = .declined
        let startup = rig.startup()
        await startup.run()

        await startup.releaseToCLI()

        #expect(rig.count(.run(LeoHandoverTests.toCLI)) == 1)
        #expect(rig.store.answer == .notAsked)
        #expect(startup.status == .usingCLI(offerTakeover: false, isRunning: true))
        #expect(!startup.summary.isManaged)
    }

    @Test func aFailedReleaseKeepsTheAppInChargeAndSaysWhy() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))
        rig.base.runner.on(LeoHandoverTests.toCLI, .exit(1, stdout: #"{"error":"drain_timeout","message":"1 agent still busy"}"#))
        let startup = rig.startup()
        await startup.run()

        await startup.releaseToCLI()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(rig.presenter.errors.count == 1)
    }

    // MARK: repair and blocking states (B9)

    @Test func anInvalidMarkerIsRewrittenFromThisBundleAndRegisteredAgain() async {
        let rig = Rig()
        rig.base.fileSystem.addFile(LeoManagedSetupTests.marker, "{", mode: 0o600)
        rig.base.probe.script(.live(version: "0.57.0"))
        // The agent is enabled, so SMAppService says it already is.
        rig.base.agent.answerAlreadyRegisteredOnNextRegister()

        let startup = rig.startup()
        await startup.run()

        let stateDirectory = LeoManagedEvent.fs(.createDirectory("/home/test/.leo/state", mode: 0o700))
        let restart: [LeoManagedEvent] = [.agent("register"), .agent("unregister"), .agent("register")]
        #expect(rig.log.events == LeoManagedSetupTests.freshInstallOps.filter { $0 != stateDirectory } + restart)
        #expect(startup.status == .managed(version: "0.57.0"))
        guard case .ours(let marker) = rig.base.writtenMarker() else { Issue.record("marker not rewritten"); return }
        #expect(marker.tmuxPath == LeoManagedSetupTests.tmuxCopy)
    }

    @Test func anOrphanRegistrationIsRemovedThenTheLaunchIsDecidedAgain() async {
        let rig = Rig()
        rig.base.agent.script(status: .enabled, .notRegistered)
        rig.base.fileSystem.addFile("/home/test/Library/LaunchAgents/com.blackpaw.leo.plist", "<plist/>")
        rig.base.probe.script(.live(version: "0.56.0"))

        let startup = rig.startup()
        await startup.run()

        #expect(rig.log.events == [.agent("unregister")])
        #expect(startup.status == .usingCLI(offerTakeover: true, isRunning: true))
    }

    @Test func anOrphanThatWontGoAwayIsReportedNotRetriedInALoop() async {
        let rig = Rig()
        rig.base.agent.script(status: .enabled)

        let startup = rig.startup()
        await startup.run()

        #expect(rig.count(.agent("unregister")) == 1)
        guard case .failed(let message) = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }
        #expect(message.contains("Login Items"))
    }

    @Test func aFailedOrphanUnregisterIsReported() async {
        let rig = Rig()
        rig.base.agent.script(status: .enabled)
        rig.base.agent.failNextUnregister()

        let startup = rig.startup()
        await startup.run()

        #expect(rig.count(.agent("unregister")) == 1)
        guard case .failed = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }
    }

    @Test func anIncompleteBundleSaysToReinstallAndTouchesNothing() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.agent.script(status: .notFound)

        let startup = rig.startup()
        await startup.run()

        #expect(rig.log.events.isEmpty)
        guard case .failed(let message) = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }
        #expect(message.contains("Download Leo again"))
    }

    @Test func aManagedAppMovedOutOfApplicationsBlocksAndLeavesTheDaemonAlone() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))

        let startup = rig.startup(location: .needsMove(.elsewhere))
        await startup.run()

        #expect(startup.status == .moveRequired(isManaged: true))
        #expect(rig.presenter.moveBackAlerts == 1)
        #expect(rig.log.events.isEmpty)
        #expect(startup.presentation.banner?.title == "Move Leo back to Applications")
    }

    // MARK: after a Sparkle update (B6)

    /// A managed 0.57.0 daemon found by an app that now bundles 0.57.1.
    func updatedRig(restartReply: LeoScriptedRunner.Reply = .exit(0, stdout: LeoPostUpdateRestartTests.restartedJSON)) throws -> Rig {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.runner.on([LeoHandoverTests.bundled, "version"], .exit(0, stdout: "leo 0.57.1\n"))
        rig.base.runner.on(LeoPostUpdateRestartTests.restart, restartReply)
        rig.base.probe.script(.live(version: "0.57.0"), .live(version: "0.57.1"))
        return rig
    }

    @Test func anUpdatedAppRestartsItsDaemonOnce() async throws {
        let rig = try updatedRig()
        var banners: [String] = []
        let startup = rig.startup()
        startup.onChange = { banners.append($0.banner?.title ?? "") }

        await startup.run()
        await startup.restartIfUpdated()
        await startup.restartIfUpdated()

        #expect(startup.status == .managed(version: "0.57.1"))
        #expect(rig.count(.run(LeoPostUpdateRestartTests.restart)) == 1)
        #expect(banners.contains("Updating Leo’s daemon to 0.57.1…"))
        #expect(startup.presentation.banner == nil)
    }

    @Test func aDaemonThatStaysOldPointsAtLeoDoctorAndIsNotRestartedAgain() async throws {
        let rig = try updatedRig()
        rig.base.probe.script(.live(version: "0.57.0"))
        let startup = rig.startup()

        await startup.run()
        await startup.restartIfUpdated()
        await startup.restartIfUpdated()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(rig.count(.run(LeoPostUpdateRestartTests.restart)) == 1)
        #expect(startup.presentation.banner?.detail.contains("leo doctor") == true)
    }

    @Test(arguments: [
        (#"{"error":"drain_timeout","message":"2 agents still busy"}"#, "Restart Daemon"),
        (#"{"error":"not_registered","message":"no job"}"#, "leo doctor"),
        (#"{"error":"restart_failed","message":"kickstart failed"}"#, "leo doctor"),
    ])
    func aRestartThatDidNotHappenKeepsTheOldDaemonAndSaysWhatToDo(json: String, advice: String) async throws {
        let rig = try updatedRig(restartReply: .exit(1, stdout: json))
        let startup = rig.startup()

        await startup.run()
        await startup.restartIfUpdated()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(startup.presentation.banner?.detail.contains(advice) == true)
        #expect(startup.presentation.banner?.actions == [.dismiss])
    }

    @Test func aDaemonRunningTheBundledVersionIsLeftAlone() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))
        let startup = rig.startup()

        await startup.run()
        await startup.restartIfUpdated()

        #expect(rig.count(.run(LeoPostUpdateRestartTests.restart)) == 0)
        #expect(startup.status == .managed(version: "0.57.0"))
    }

    @Test func aCLIDaemonIsNeverRestarted() async throws {
        let rig = Rig()
        rig.base.runner.on([LeoHandoverTests.bundled, "version"], .exit(0, stdout: "leo 0.57.1\n"))
        rig.base.probe.script(.live(version: "0.57.0"))
        rig.base.agent.script(status: .notRegistered)
        let startup = rig.startup()

        await startup.run()
        await startup.restartIfUpdated()

        #expect(rig.count(.run([LeoHandoverTests.bundled, "version"])) == 0)
        #expect(rig.count(.run(LeoPostUpdateRestartTests.restart)) == 0)
    }

    // MARK: presentation

    @Test(arguments: [
        (LeoManagedStatus.inactive, LeoDaemonStartAction.startCLIDaemon, [LeoManagedBannerAction]?.none),
        (.usingCLI(offerTakeover: true, isRunning: false), .startCLIDaemon, [.takeOver, .notNow]),
        (.usingCLI(offerTakeover: false, isRunning: false), .startCLIDaemon, nil),
        (.settingUp, .setUp, []),
        (.awaitingApproval, .allowInLoginItems, [.openLoginItems]),
        (.managed(version: "0.57.0"), .setUp, nil),
        (.moveRequired(isManaged: true), .moveToApplications, [.moveToApplications]),
        // The A9 banner already says it.
        (.moveRequired(isManaged: false), .moveToApplications, nil),
        (.failed(message: "boom"), .setUp, [.retry]),
        (.updating(to: "0.57.1"), .setUp, []),
    ])
    func eachStatusHasItsStartButtonAndBanner(
        status: LeoManagedStatus, startAction: LeoDaemonStartAction, actions: [LeoManagedBannerAction]?
    ) {
        let presentation = LeoManagedPresentation(status: status, notice: nil)
        #expect(presentation.startAction == startAction)
        #expect(presentation.banner?.actions == actions)
    }

    @Test func theStartButtonTitlesAreTheActionNames() {
        #expect(LeoDaemonStartAction.setUp.title == "Set Up Daemon")
        #expect(LeoDaemonStartAction.allowInLoginItems.title == "Allow in Login Items…")
        #expect(LeoDaemonStartAction.moveToApplications.title == "Move to Applications…")
        #expect(LeoDaemonStartAction.startCLIDaemon.title == "Start CLI Daemon")
    }

    // MARK: LeoRuntime

    @Test func theSidebarStartButtonRunsTheManagedActionWhenTheAppManages() {
        let model = LeoSidebarModel()
        var cliStarts = 0
        var actions: [LeoDaemonStartAction] = []
        model.startDaemonRequested = { cliStarts += 1 }

        model.startDaemonTapped()
        model.daemonStartActionRequested = { actions.append($0) }
        model.managedPresentationChanged(LeoManagedPresentation(status: .awaitingApproval, notice: nil))
        model.startDaemonTapped()

        #expect(cliStarts == 1)
        #expect(actions == [.allowInLoginItems])
        #expect(model.managedBanner == LeoManagedPresentation(status: .awaitingApproval, notice: nil).banner)
    }

    @MainActor final class Recorded {
        var value: Bool?
        var count = 0
    }

    @Test func theRuntimeRunsManagedStartupBeforeHostSelectionStarts() async throws {
        let defaults = LeoInMemoryDefaults()
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        defaults.set(try JSONEncoder().encode([configuration]), forKey: LeoHostStore.key)
        let daemon = RuntimeTestDaemon()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(
            daemon: daemon, cli: .recordingForTests(), activitySource: activitySource, defaults: defaults,
            templateFetchRunner: LeoRecordingTemplateRunner()
        )
        defer { runtime.shutdown() }
        let hostsLoadedDuringStartup = Recorded()
        runtime.managedStartup = { hostsLoadedDuringStartup.value = !runtime.hostSelection.hosts.isEmpty }

        runtime.start()

        await awaitCondition(message: "host selection never started") { await MainActor.run { !runtime.hostSelection.hosts.isEmpty } }
        #expect(hostsLoadedDuringStartup.value == false)
    }
}
