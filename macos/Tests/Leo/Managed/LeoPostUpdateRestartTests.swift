import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B6: after a Sparkle update the bundled leo differs from the running
/// daemon. The policy table, the exact argv and op log, each `restart --json`
/// answer, and no restart loop. Every seam is a fake.
struct LeoPostUpdateRestartTests {
    typealias Setup = LeoManagedSetupTests

    static let restart = [Setup.helper, "service", "restart", "--graceful", "--json"]
    static let oldTmux = "/home/test/.leo/app/tmux/3.6b/tmux"
    static let newVersionDir = "/home/test/.leo/app/tmux/3.6c"
    static let newTmux = "/home/test/.leo/app/tmux/3.6c/tmux"
    static let restartedJSON = #"{"ok":true,"drained":true,"restarted":true}"#

    /// The app was 0.57.0 with tmux 3.6b; Sparkle installed 0.57.1 with 3.6c.
    struct Rig {
        let base = Setup.Rig()
        var log: LeoManagedEventLog { base.log }

        init() {
            base.runner.on([Setup.helper, "version"], .exit(0, stdout: "leo 0.57.1\n"))
            base.runner.on([Setup.bundledTmux, "-V"], .exit(0, stdout: "tmux 3.6c\n"))
            base.fileSystem.addFile(LeoPostUpdateRestartTests.oldTmux, "tmux-3.6b", mode: 0o755)
            base.probe.script(.live(version: "0.57.1"))
        }

        var restarter: LeoPostUpdateRestart {
            LeoPostUpdateRestart(
                runner: base.runner, bundledLeo: Setup.helper,
                tmux: LeoTmuxInstaller(paths: Setup.paths, fileSystem: base.fileSystem, runner: base.runner, makeToken: base.tokens.next),
                markerStore: markerStore, probe: base.probe, clock: base.clock
            )
        }

        var markerStore: LeoMarkerStore { LeoMarkerStore(paths: Setup.paths, fileSystem: base.fileSystem, bundleID: Setup.bundleID) }

        func writeMarker(tmuxPath: String = LeoPostUpdateRestartTests.oldTmux) throws {
            let marker = LeoManagedMarker(
                bundleID: Setup.bundleID, launchdLabel: Setup.label, selfPath: Setup.link, tmuxPath: tmuxPath, env: ["PATH": "/x"]
            )
            base.fileSystem.addFile(Setup.marker, try marker.encoded(), mode: 0o600)
        }
    }

    // MARK: policy

    @Test(arguments: [
        (true, "0.57.1", "0.57.0", false, true),
        (true, "0.57.0", "0.57.1", false, true),
        (true, "0.57.1", "0.57.1", false, false),
        (false, "0.57.1", "0.57.0", false, false),
        (true, "0.57.1", "0.57.0", true, false),
        (true, "0.57.1", "v0.57.1", false, true),
    ])
    func restartsOnAnyDifferenceOnlyWhenManagedAndNotYetTried(
        managedByUs: Bool, bundled: String, running: String, tried: Bool, expected: Bool
    ) {
        #expect(LeoPostUpdateRestart.shouldRestart(
            managedByUs: managedByUs, bundled: bundled, running: running, alreadyTriedPair: tried
        ) == expected)
    }

    @Test(arguments: [
        ("leo 0.57.1\n", Int32(0), "0.57.1"),
        ("0.57.1", 0, "0.57.1"),
        ("leo 0.58.0-dev+abc\n", 0, "0.58.0-dev+abc"),
        ("", 0, nil),
        ("leo 0.57.1\n", 1, nil),
    ])
    func theBundledVersionIsLeoVersionMinusThePrefix(stdout: String, status: Int32, expected: String?) async {
        let rig = Rig()
        rig.base.runner.on([Setup.helper, "version"], .exit(status, stdout: stdout))

        #expect(await rig.restarter.bundledVersion() == expected)
    }

    // MARK: restart

    @Test func copiesTheNewTmuxRepointsTheMarkerThenRestartsGracefully() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(0, stdout: Self.restartedJSON))

        let outcome = await rig.restarter.restart(bundled: "0.57.1")

        #expect(outcome == .restarted(version: "0.57.1"))
        #expect(rig.log.events == [
            .run([Setup.bundledTmux, "-V"]),
            .fs(.createDirectory(Self.newVersionDir, mode: 0o755)),
            .fs(.copy(Setup.bundledTmux, "\(Self.newVersionDir)/.tmux.c1.tmp")),
            .fs(.chmod("\(Self.newVersionDir)/.tmux.c1.tmp", mode: 0o755)),
            .fs(.moveNoReplace("\(Self.newVersionDir)/.tmux.c1.tmp", Self.newTmux)),
            .fs(.write("/home/test/.leo/state/.managed.json.t1.tmp", mode: 0o600)),
            .fs(.rename("/home/test/.leo/state/.managed.json.t1.tmp", Setup.marker)),
            .run(Self.restart),
        ])
        #expect(rig.base.runner.timeouts[Self.restart] == LeoHandover.timeout)
        // The old version dir a `-L leo` server may use is kept.
        #expect(rig.base.fileSystem.contents(of: Self.oldTmux) == "tmux-3.6b")
        guard case .ours(let marker) = rig.markerStore.read() else { Issue.record("no marker"); return }
        #expect(marker.tmuxPath == Self.newTmux)
        #expect(marker.env == ["PATH": "/x"])
    }

    @Test func anUnchangedTmuxLeavesTheMarkerAlone() async throws {
        let rig = Rig()
        rig.base.runner.on([Setup.bundledTmux, "-V"], .exit(0, stdout: "tmux 3.6b\n"))
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(0, stdout: Self.restartedJSON))

        _ = await rig.restarter.restart(bundled: "0.57.1")

        #expect(rig.log.events == [.run([Setup.bundledTmux, "-V"]), .run(Self.restart)])
    }

    @Test func waitsPastTheOldDaemonForTheNewVersion() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(0, stdout: Self.restartedJSON))
        rig.base.probe.script(.live(version: "0.57.0"), .absent, .live(version: "0.57.1"))

        #expect(await rig.restarter.restart(bundled: "0.57.1") == .restarted(version: "0.57.1"))
        #expect(rig.base.clock.seconds == 1)
    }

    @Test func aDaemonStillOnTheOldVersionIsReported() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(0, stdout: Self.restartedJSON))
        rig.base.probe.script(.live(version: "0.57.0"))

        #expect(await rig.restarter.restart(bundled: "0.57.1") == .stillDifferent(bundled: "0.57.1", running: "0.57.0"))
        #expect(rig.base.clock.seconds == LeoManagedSetup.helloTimeout)
    }

    @Test func aDaemonThatNeverComesBackIsReported() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(0, stdout: Self.restartedJSON))
        rig.base.probe.script(.absent)

        #expect(await rig.restarter.restart(bundled: "0.57.1") == .stillDifferent(bundled: "0.57.1", running: nil))
    }

    @Test func notRegisteredIsReportedWithLeosMessage() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(
            Self.restart, .exit(1, stdout: #"{"ok":false,"error":"not_registered","message":"no job studio.blackpaw.leo.daemon"}"#)
        )

        #expect(await rig.restarter.restart(bundled: "0.57.1") == .notRegistered(message: "no job studio.blackpaw.leo.daemon"))
        #expect(rig.base.probe.probes == 0)
    }

    @Test func aDrainTimeoutLeavesTheOldDaemonRunning() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, .exit(1, stdout: #"{"ok":false,"error":"drain_timeout"}"#))

        #expect(await rig.restarter.restart(bundled: "0.57.1") == .drainTimedOut)
        #expect(rig.base.probe.probes == 0)
    }

    @Test(arguments: [
        LeoScriptedRunner.Reply.exit(0, stdout: "not json"),
        .exit(1, stdout: #"{"ok":true}"#),
        .exit(0, stdout: #"{"ok":false,"error":"x"}"#),
        .exit(2, stdout: #"{"ok":false,"error":"boom","message":"it broke"}"#),
        .error(LeoRestartTestError.boom),
    ])
    func anyOtherAnswerIsAFailure(reply: LeoScriptedRunner.Reply) async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on(Self.restart, reply)

        guard case .failed = await rig.restarter.restart(bundled: "0.57.1") else {
            Issue.record("expected .failed")
            return
        }
        #expect(rig.base.probe.probes == 0)
    }

    @Test func aTmuxCopyFailureRestartsNothing() async throws {
        let rig = Rig()
        try rig.writeMarker()
        rig.base.runner.on([Setup.bundledTmux, "-V"], .exit(1, stderr: "dyld: missing"))

        guard case .failed = await rig.restarter.restart(bundled: "0.57.1") else {
            Issue.record("expected .failed")
            return
        }
        #expect(!rig.log.events.contains(.run(Self.restart)))
    }

    @Test func aMarkerThatIsNoLongerOursRestartsNothing() async {
        let rig = Rig()

        guard case .failed = await rig.restarter.restart(bundled: "0.57.1") else {
            Issue.record("expected .failed")
            return
        }
        #expect(!rig.log.events.contains(.run(Self.restart)))
    }
}

enum LeoRestartTestError: Error, Sendable { case boom }
