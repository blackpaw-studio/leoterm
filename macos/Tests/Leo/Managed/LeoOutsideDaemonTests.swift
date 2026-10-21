import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B10: a leo daemon answering while the app's job isn't loaded. Only the
/// pid `/health` reports, checked again just before, is ever signalled.
struct LeoOutsideDaemonTests {
    static let pid: Int32 = 4242

    struct Rig {
        let base = LeoManagedSetupTests.Rig()
        let signaller: LeoFakeSignaller
        var log: LeoManagedEventLog { base.log }

        init() {
            signaller = LeoFakeSignaller(log: base.log)
            // Answering until the signal, then gone.
            base.probe.scriptHealth(
                .answered(version: "0.56.0", pid: LeoOutsideDaemonTests.pid),
                .answered(version: "0.56.0", pid: LeoOutsideDaemonTests.pid),
                .absent
            )
            base.probe.script(.live(version: "0.56.1"))
        }

        var stopper: LeoOutsideDaemonStop {
            LeoOutsideDaemonStop(agent: base.agent, probe: base.probe, signaller: signaller, clock: base.clock)
        }
    }

    @Test func signalsTheReportedPidWaitsForItToGoThenRestartsTheAppsJob() async {
        let rig = Rig()

        #expect(await rig.stopper.run(pid: Self.pid) == .managed(version: "0.56.1"))

        #expect(rig.log.events == [.signal(Self.pid), .agent("unregister"), .agent("register")])
        #expect(rig.base.probe.healthChecks == 3)
        #expect(rig.base.clock.seconds == LeoOutsideDaemonStop.pollInterval)
    }

    @Test func anUnregisteredAppJobIsRegisteredWithoutAnUnregister() async {
        let rig = Rig()
        rig.base.agent.script(status: .notRegistered)

        _ = await rig.stopper.run(pid: Self.pid)

        #expect(rig.log.events == [.signal(Self.pid), .agent("register")])
    }

    @Test(arguments: [
        LeoDaemonHealthCheck.answered(version: "0.56.0", pid: 5555),
        .answered(version: "0.56.0", pid: nil),
        .unresponsive,
    ])
    func aDaemonThatCantBeConfirmedIsNeverSignalled(recheck: LeoDaemonHealthCheck) async {
        let rig = Rig()
        rig.base.probe.scriptHealth(recheck)

        guard case .changed = await rig.stopper.run(pid: Self.pid) else { Issue.record("expected .changed"); return }

        #expect(rig.log.events.isEmpty)
    }

    @Test func aDaemonAlreadyGoneIsNotSignalledAndTheAppsJobStarts() async {
        let rig = Rig()
        rig.base.probe.scriptHealth(.absent)

        #expect(await rig.stopper.run(pid: Self.pid) == .managed(version: "0.56.1"))
        #expect(!rig.log.events.contains(.signal(Self.pid)))
    }

    @Test func aDaemonThatWontStopTimesOutAndStartsNothing() async {
        let rig = Rig()
        rig.base.probe.scriptHealth(.answered(version: "0.56.0", pid: Self.pid))

        #expect(await rig.stopper.run(pid: Self.pid) == .didNotStop(pid: Self.pid))

        #expect(rig.base.clock.seconds == LeoOutsideDaemonStop.stopTimeout)
        #expect(rig.log.events == [.signal(Self.pid)])
    }

    @Test func aRefusedSignalStartsNothing() async {
        let rig = Rig()
        rig.signaller.refuseNext()

        guard case .signalFailed = await rig.stopper.run(pid: Self.pid) else { Issue.record("expected .signalFailed"); return }
        #expect(rig.log.events == [.signal(Self.pid)])
    }

    @Test func anAppJobThatNeverAnswersIsAFailure() async {
        let rig = Rig()
        rig.base.probe.script(.absent)

        guard case .failed = await rig.stopper.run(pid: Self.pid) else { Issue.record("expected .failed"); return }
    }

    @Test func pendingApprovalStartsNothing() async {
        let rig = Rig()
        rig.base.agent.script(status: .requiresApproval)

        #expect(await rig.stopper.run(pid: Self.pid) == .awaitingApproval)
        #expect(rig.log.events == [.signal(Self.pid)])
    }

    @Test(arguments: [Int32(0), 1, -1])
    func theLiveSignallerRefusesPidsThatArentADaemon(pid: Int32) {
        #expect(throws: LeoSignalError.self) { try LeoPOSIXSignaller().terminate(pid: pid) }
    }

    @Test func theLiveSignallerRefusesThisProcess() {
        #expect(throws: LeoSignalError.self) { try LeoPOSIXSignaller().terminate(pid: getpid()) }
    }
}
