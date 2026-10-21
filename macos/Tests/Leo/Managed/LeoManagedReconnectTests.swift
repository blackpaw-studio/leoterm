import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app itself restarting or switching the daemon (takeover, Try Again,
/// approval, post-update restart, stopping an outside daemon) leaves the
/// sidebar on a closed connection: once the new daemon answers hello the
/// existing reconnect runs, once. Launch never reconnects (host selection
/// starts after the managed step).
@MainActor struct LeoManagedReconnectTests {
    typealias Rig = LeoRuntimeManagedStartTests.Rig

    final class Reconnects {
        var count = 0
    }

    private func startup(_ rig: Rig, _ reconnects: Reconnects) -> LeoManagedStartup {
        let startup = rig.startup()
        startup.daemonChanged = { reconnects.count += 1 }
        return startup
    }

    /// A managed 0.57.0 daemon found by an app that now bundles 0.57.1.
    private func updatedRig(restartReply: LeoScriptedRunner.Reply = .exit(0, stdout: LeoPostUpdateRestartTests.restartedJSON)) throws -> Rig {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.runner.on([LeoHandoverTests.bundled, "version"], .exit(0, stdout: "leo 0.57.1\n"))
        rig.base.runner.on(LeoPostUpdateRestartTests.restart, restartReply)
        rig.base.probe.script(.live(version: "0.57.0"), .live(version: "0.57.1"))
        return rig
    }

    @Test func launchNeverReconnects() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))
        let reconnects = Reconnects()

        await startup(rig, reconnects).run()

        #expect(reconnects.count == 0)
    }

    @Test func aFreshSetupAtLaunchNeverReconnects() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered, .enabled)
        let reconnects = Reconnects()

        await startup(rig, reconnects).run()

        #expect(reconnects.count == 0)
    }

    @Test func tryAgainAfterAFailedLaunchReconnectsOnceTheDaemonAnswers() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.absent)
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()
        guard case .failed = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }

        rig.base.probe.script(.live(version: "0.57.0"))
        await startup.perform(.retry)

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 1)
    }

    @Test func tryAgainThatStillFindsNoDaemonDoesNotReconnect() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.absent)
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()

        await startup.perform(.retry)

        #expect(reconnects.count == 0)
    }

    @Test func aTakeoverReconnectsToTheNewDaemon() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()

        rig.base.agent.script(status: .enabled)
        rig.base.probe.script(.live(version: "0.57.0"))
        await startup.perform(.takeOver)

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 1)
    }

    @Test func aTakeoverLeoCannotDoLeavesTheConnectionAlone() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        rig.base.runner.on(LeoHandoverTests.toApp, .exit(1, stdout: #"{"ok":false,"step":"preflight","error":"no_launchd_job"}"#))
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()

        await startup.perform(.takeOver)

        #expect(reconnects.count == 0)
    }

    @Test func approvalGrantedInLoginItemsReconnects() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.agent.script(status: .requiresApproval)
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()

        rig.base.agent.script(status: .enabled)
        await startup.applicationDidBecomeActive()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 1)
    }

    @Test func aPostUpdateRestartReconnects() async throws {
        let rig = try updatedRig()
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)

        await startup.run()
        await startup.restartIfUpdated()

        #expect(startup.status == .managed(version: "0.57.1"))
        #expect(reconnects.count == 1)
    }

    @Test func aRestartThatLeftTheOldVersionStillReconnects() async throws {
        let rig = try updatedRig()
        rig.base.probe.script(.live(version: "0.57.0"))
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)

        await startup.run()
        await startup.restartIfUpdated()

        #expect(reconnects.count == 1)
    }

    @Test func aRestartThatDidNotHappenDoesNotReconnect() async throws {
        let rig = try updatedRig(restartReply: .exit(1, stdout: #"{"error":"drain_timeout","message":"2 agents still busy"}"#))
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)

        await startup.run()
        await startup.restartIfUpdated()

        #expect(reconnects.count == 0)
    }

    @Test func stoppingAnOutsideDaemonReconnectsToTheAppsJob() async throws {
        let rig = try updatedRig(restartReply: .exit(1, stdout: #"{"error":"not_registered","message":"no launchd job"}"#))
        rig.base.probe.scriptHealth(
            .answered(version: "0.57.0", pid: 4242), .answered(version: "0.57.0", pid: 4242),
            .answered(version: "0.57.0", pid: 4242), .absent
        )
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()
        await startup.restartIfUpdated()
        #expect(reconnects.count == 0)

        await startup.perform(.stopOutsideDaemon)

        #expect(startup.status == .managed(version: "0.57.1"))
        #expect(reconnects.count == 1)
    }

    @Test func decliningToStopAnOutsideDaemonDoesNotReconnect() async throws {
        let rig = try updatedRig(restartReply: .exit(1, stdout: #"{"error":"not_registered","message":"no launchd job"}"#))
        rig.base.probe.scriptHealth(.answered(version: "0.57.0", pid: 4242))
        rig.presenter.confirmsStop = false
        let reconnects = Reconnects()
        let startup = startup(rig, reconnects)
        await startup.run()
        await startup.restartIfUpdated()

        await startup.perform(.stopOutsideDaemon)

        #expect(reconnects.count == 0)
    }
}
