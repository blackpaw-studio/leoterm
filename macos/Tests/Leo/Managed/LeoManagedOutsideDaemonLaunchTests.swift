import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B10 at launch and from the menu: a daemon answers while the app's job
/// isn't loaded, even when its version matches the bundled one.
@MainActor struct LeoManagedOutsideDaemonLaunchTests {
    typealias Rig = LeoRuntimeManagedStartTests.Rig

    static let launchctlPrint = ["/bin/launchctl", "print", "gui/\(getuid())/\(LeoManagedSetupTests.label)"]

    /// A managed marker, the app's job registered, and a matching-version
    /// daemon with pid 4242 answering.
    private func launchRig(jobExit: Int32?, health: LeoDaemonHealthCheck = .answered(version: "0.57.0", pid: 4242)) throws -> Rig {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.probe.script(.live(version: "0.57.0"))
        rig.base.probe.scriptHealth(health)
        if let jobExit { rig.base.runner.on(Self.launchctlPrint, .exit(jobExit, stderr: "Could not find service")) }
        return rig
    }

    @Test func aMatchingDaemonOutsideTheJobIsOfferedForStoppingAtLaunch() async throws {
        let rig = try launchRig(jobExit: 113)
        let startup = rig.startup()

        await startup.run()

        #expect(startup.status == .runningOutsideJob(pid: 4242))
        #expect(startup.summary == LeoManagedSummary(isManaged: true, isOutsideDaemon: true, version: nil))
        #expect(startup.presentation.banner?.actions == [.stopOutsideDaemon])
        #expect(!rig.log.events.contains { if case .signal = $0 { true } else { false } })
    }

    @Test func aLoadedJobMeansTheDaemonIsTheApps() async throws {
        let rig = try launchRig(jobExit: 0)
        let startup = rig.startup()

        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
    }

    @Test func aJobStateLaunchctlCannotGiveNeverAccusesTheDaemon() async throws {
        let rig = try launchRig(jobExit: nil)
        let startup = rig.startup()

        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
    }

    @Test func aDaemonWithoutAPidCannotBeOfferedForStopping() async throws {
        let rig = try launchRig(jobExit: 113, health: .answered(version: "0.57.0", pid: nil))
        let startup = rig.startup()

        await startup.run()

        #expect(startup.status == .managed(version: "0.57.0"))
    }

    @Test func stoppingTheLaunchTimeOutsideDaemonHandsItToTheAppsJob() async throws {
        let rig = try launchRig(jobExit: 113)
        rig.base.probe.scriptHealth(.answered(version: "0.57.0", pid: 4242), .answered(version: "0.57.0", pid: 4242), .absent)
        rig.base.probe.script(.live(version: "0.57.0"), .live(version: "0.57.0"), .absent, .live(version: "0.57.0"))
        let startup = rig.startup()
        await startup.run()

        await startup.perform(.stopOutsideDaemon)

        #expect(Array(rig.log.events.suffix(3)) == [.signal(4242), .agent("unregister"), .agent("register")])
        #expect(startup.status == .managed(version: "0.57.0"))
    }

    // MARK: Restart Daemon says not_registered

    @Test func aMenuRestartThatFindsNoJobOffersToStopTheDaemonAnswering() async throws {
        let rig = try launchRig(jobExit: 0)
        let startup = rig.startup()
        await startup.run()
        rig.base.probe.scriptHealth(.answered(version: "0.57.0", pid: 4242))

        await startup.restartFoundNoJob()

        #expect(startup.status == .runningOutsideJob(pid: 4242))
        #expect(startup.presentation.banner?.actions == [.stopOutsideDaemon])
    }

    @Test func aMenuRestartThatFindsNoJobAndNoDaemonPointsAtLeoDoctor() async throws {
        let rig = try launchRig(jobExit: 0)
        let startup = rig.startup()
        await startup.run()
        rig.base.probe.scriptHealth(.absent)

        await startup.restartFoundNoJob()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(startup.presentation.banner?.detail.contains("leo doctor") == true)
        #expect(startup.presentation.banner?.actions == [.dismiss])
    }
}
