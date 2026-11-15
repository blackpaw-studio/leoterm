import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B2: the setup executor's exact op log, its rollback for each failing
/// step, and the Login Items approval path. Every seam is a fake.
struct LeoManagedSetupTests {
    static let home = "/home/test"
    static let bundledTmux = "/Applications/Leo.app/Contents/Helpers/tmux"
    static let helper = "/Applications/Leo.app/Contents/Helpers/leo"
    static let agentPlist = "/Applications/Leo.app/Contents/Library/LaunchAgents/studio.blackpaw.leo.daemon.plist"
    static let versionDir = "/home/test/.leo/app/tmux/3.6b"
    static let tmuxCopy = "/home/test/.leo/app/tmux/3.6b/tmux"
    static let tmuxTemp = "/home/test/.leo/app/tmux/3.6b/.tmux.c1.tmp"
    static let link = "/home/test/.leo/app/bin/leo"
    static let marker = "/home/test/.leo/state/managed.json"
    static let label = "studio.blackpaw.leo.daemon"
    static let bundleID = "studio.blackpaw.leo.macos"
    static let terminfo = "/Applications/Leo.app/Contents/Resources/terminfo"

    static let paths = LeoInstallPaths(
        home: URL(fileURLWithPath: home, isDirectory: true),
        bundleURL: URL(fileURLWithPath: "/Applications/Leo.app")
    )

    /// The ops a fresh install makes before it registers.
    static let freshInstallOps: [LeoManagedEvent] = [
        .run([bundledTmux, "-V"]),
        .fs(.createDirectory(versionDir, mode: 0o755)),
        .fs(.copy(bundledTmux, tmuxTemp)),
        .fs(.chmod(tmuxTemp, mode: 0o755)),
        .fs(.moveNoReplace(tmuxTemp, tmuxCopy)),
        .fs(.createDirectory("/home/test/.leo/app/bin", mode: 0o755)),
        .fs(.symlink("/home/test/.leo/app/bin/.leo.t1.tmp", target: helper)),
        .fs(.rename("/home/test/.leo/app/bin/.leo.t1.tmp", link)),
        .fs(.createDirectory("/home/test/.leo/state", mode: 0o700)),
        .fs(.write("/home/test/.leo/state/.managed.json.t2.tmp", mode: 0o600)),
        .fs(.rename("/home/test/.leo/state/.managed.json.t2.tmp", marker)),
    ]

    struct Rig {
        let log = LeoManagedEventLog()
        let fileSystem = LeoInMemoryFileSystem()
        let runner: LeoScriptedRunner
        let agent: LeoFakeLaunchAgent
        let probe = LeoFakeProbe(.absent, .absent, .live(version: "0.57.0"))
        let clock = LeoJumpingClock()
        let tokens = LeoSequentialTokens()

        init(isInApplications _: Bool = true) {
            runner = LeoScriptedRunner(log: log)
            agent = LeoFakeLaunchAgent(log: log, status: .enabled)
            fileSystem.addFile(LeoManagedSetupTests.bundledTmux, "tmux-3.6b", mode: 0o755)
            fileSystem.addFile(LeoManagedSetupTests.helper, "leo", mode: 0o755)
            fileSystem.addFile(LeoManagedSetupTests.agentPlist, "plist", mode: 0o644)
            runner.on([LeoManagedSetupTests.bundledTmux, "-V"], .exit(0, stdout: "tmux 3.6b\n"))
            let log = log
            fileSystem.observe { log.append(.fs($0)) }
        }

        func setup(isInApplications: Bool = true) -> LeoManagedSetup {
            LeoManagedSetup(
                paths: LeoManagedSetupTests.paths,
                fileSystem: fileSystem,
                tmux: LeoTmuxInstaller(paths: LeoManagedSetupTests.paths, fileSystem: fileSystem, runner: runner, makeToken: tokens.next),
                agent: agent,
                probe: probe,
                clock: clock,
                loginPath: { "/usr/bin:/bin" },
                bundleID: LeoManagedSetupTests.bundleID,
                label: LeoManagedSetupTests.label,
                isInApplications: isInApplications
            )
        }

        func writtenMarker() -> LeoMarkerState {
            LeoMarkerStore(paths: LeoManagedSetupTests.paths, fileSystem: fileSystem, bundleID: LeoManagedSetupTests.bundleID).read()
        }
    }

    // MARK: happy path

    @Test func freshInstallCopiesTmuxLinksWritesTheMarkerRegistersAndWaitsForHello() async throws {
        let rig = Rig()

        let outcome = await rig.setup().run()

        #expect(outcome == .ready(version: "0.57.0"))
        #expect(rig.log.events == Self.freshInstallOps + [.agent("register")])
        #expect(rig.probe.probes == 3)
        #expect(rig.clock.seconds == 1)
        #expect(rig.fileSystem.contents(of: Self.tmuxCopy) == "tmux-3.6b")
    }

    @Test func theMarkerNamesTheLinkTheTmuxCopyAndTheLoginEnvironment() async throws {
        let rig = Rig()

        _ = await rig.setup().run()

        let expected = LeoManagedMarker(
            bundleID: Self.bundleID, launchdLabel: Self.label, selfPath: Self.link, tmuxPath: Self.tmuxCopy,
            env: [
                "PATH": "/home/test/.local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin",
                "TERMINFO_DIRS": Self.terminfo,
            ]
        )
        #expect(rig.writtenMarker() == .ours(expected))
    }

    @Test func aCapturedEnvironmentWinsOverTheLoginPath() async throws {
        let rig = Rig()

        _ = await rig.setup().run(captured: ["PATH": "/custom/bin", "FOO": "bar", "SSH_AUTH_SOCK": "/tmp/agent"])

        guard case .ours(let marker) = rig.writtenMarker() else { Issue.record("no marker"); return }
        #expect(marker.env?["FOO"] == "bar")
        #expect(marker.env?["SSH_AUTH_SOCK"] == nil)
        #expect(marker.env?["PATH"]?.hasPrefix("/home/test/.local/bin:/custom/bin:") == true)
    }

    // MARK: tmux version dirs

    @Test func anExistingVersionCopyIsNeverOverwritten() async throws {
        let rig = Rig()
        rig.fileSystem.addFile(Self.tmuxCopy, "older-but-in-use", mode: 0o755)

        _ = await rig.setup().run()

        #expect(rig.fileSystem.contents(of: Self.tmuxCopy) == "older-but-in-use")
        #expect(!rig.log.events.contains { if case .fs(.copy) = $0 { true } else { false } })
        guard case .ours(let marker) = rig.writtenMarker() else { Issue.record("no marker"); return }
        #expect(marker.tmuxPath == Self.tmuxCopy)
    }

    @Test func anEmptyVersionDirIsFilledWithoutRecreatingIt() async throws {
        let rig = Rig()
        rig.fileSystem.addDirectory(Self.versionDir)

        _ = await rig.setup().run()

        #expect(Array(rig.log.events.prefix(4)) == [
            .run([Self.bundledTmux, "-V"]),
            .fs(.copy(Self.bundledTmux, Self.tmuxTemp)),
            .fs(.chmod(Self.tmuxTemp, mode: 0o755)),
            .fs(.moveNoReplace(Self.tmuxTemp, Self.tmuxCopy)),
        ])
    }

    @Test func aCopyWhoseHashDiffersIsDiscardedAndNothingElseHappens() async throws {
        let rig = Rig()
        rig.fileSystem.corruptNextCopy()

        let outcome = await rig.setup().run()

        guard case .failed(let failure) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(failure.step == .tmux)
        #expect(rig.log.events == [
            .run([Self.bundledTmux, "-V"]),
            .fs(.createDirectory(Self.versionDir, mode: 0o755)),
            .fs(.copy(Self.bundledTmux, Self.tmuxTemp)),
            .fs(.remove(Self.tmuxTemp)),
        ])
    }

    @Test(arguments: ["tmux ../../evil\n", "tmux \n", "screen 4.9\n"])
    func anUnusableVersionStopsBeforeAnyWrite(output: String) async throws {
        let rig = Rig()
        rig.runner.on([Self.bundledTmux, "-V"], .exit(0, stdout: output))

        let outcome = await rig.setup().run()

        guard case .failed(let failure) = outcome else { Issue.record("expected failure"); return }
        #expect(failure.step == .tmux)
        #expect(rig.log.events == [.run([Self.bundledTmux, "-V"])])
    }

    @Test func aFailingVersionQueryStopsBeforeAnyWrite() async throws {
        let rig = Rig()
        rig.runner.on([Self.bundledTmux, "-V"], .exit(1, stderr: "dyld: missing"))

        guard case .failed(let failure) = await rig.setup().run() else { Issue.record("expected failure"); return }
        #expect(failure.step == .tmux)
        #expect(rig.log.events == [.run([Self.bundledTmux, "-V"])])
    }

    // MARK: link

    @Test func anOccupiedLinkPathStopsBeforeTheMarker() async throws {
        let rig = Rig()
        rig.fileSystem.addFile(Self.link, "someone else's", mode: 0o755)

        guard case .failed(let failure) = await rig.setup().run() else { Issue.record("expected failure"); return }
        #expect(failure.step == .link)
        #expect(!rig.log.events.contains(.agent("register")))
        #expect(rig.writtenMarker() == .absent)
    }

    @Test func outsideApplicationsTheLinkIsLeftAloneButTheMarkerStillNamesIt() async throws {
        let rig = Rig()

        #expect(await rig.setup(isInApplications: false).run() == .ready(version: "0.57.0"))

        #expect(!rig.log.events.contains { if case .fs(.symlink) = $0 { true } else { false } })
        guard case .ours(let marker) = rig.writtenMarker() else { Issue.record("no marker"); return }
        #expect(marker.selfPath == Self.link)
    }

    // MARK: rollback

    @Test func aFailedRegisterUnregistersAndRemovesTheMarkerButKeepsTmux() async throws {
        let rig = Rig()
        rig.agent.failNextRegister()
        rig.agent.script(status: .notRegistered)

        guard case .failed(let failure) = await rig.setup().run() else { Issue.record("expected failure"); return }
        #expect(failure.step == .register)
        #expect(rig.log.events == Self.freshInstallOps + [
            .agent("register"),
            .agent("unregister"),
            .fs(.remove(Self.marker)),
        ])
        #expect(rig.fileSystem.contents(of: Self.tmuxCopy) == "tmux-3.6b")
    }

    @Test func noHelloWithinTwentySecondsRollsBack() async throws {
        let rig = Rig()
        rig.probe.script(.absent)

        guard case .failed(let failure) = await rig.setup().run() else { Issue.record("expected failure"); return }
        #expect(failure.step == .hello)
        #expect(failure.message.contains("20 seconds"))
        #expect(failure.message.contains("~/.leo/state/service.log"))
        #expect(rig.clock.seconds == 20)
        #expect(rig.log.events == Self.freshInstallOps + [
            .agent("register"),
            .agent("unregister"),
            .fs(.remove(Self.marker)),
        ])
    }

    @Test func aSilentDaemonSaysWhereItsLogIs() {
        #expect(LeoDaemonSilent().description.contains("20 seconds"))
        #expect(LeoDaemonSilent().description.contains("~/.leo/state/service.log"))
    }

    @Test func aFailedUnregisterStillRemovesTheMarker() async throws {
        let rig = Rig()
        rig.probe.script(.absent)
        rig.agent.failNextUnregister()

        _ = await rig.setup().run()

        #expect(Array(rig.log.events.suffix(2)) == [.agent("unregister"), .fs(.remove(Self.marker))])
        #expect(rig.writtenMarker() == .absent)
    }

    static func released(managedStopped: Bool) -> LeoHandoverRun {
        .succeeded(LeoHandoverResult(previousLabel: label, env: nil, plistBackup: nil, managedStopped: managedStopped, warnings: []))
    }

    /// Activates with a hand-back that answers `answer`, after a hello
    /// timeout or, with `failRegister`, a refused register.
    private func rollBackAfterTakeover(answering answer: LeoHandoverRun, failRegister: Bool = false) async -> Rig {
        let rig = Rig()
        if failRegister {
            rig.agent.failNextRegister()
            rig.agent.script(status: .notRegistered)
        } else {
            rig.probe.script(.absent)
        }
        let setup = rig.setup()
        let log = rig.log
        guard case .success(let prepared) = await setup.prepare() else { Issue.record("prepare failed"); return rig }
        _ = await setup.activate(prepared, captured: nil, handBack: {
            log.append(.run(["hand-back"]))
            return answer
        })
        return rig
    }

    /// `--to-cli` needs the marker, boots out the app's job and removes the
    /// marker itself once the CLI daemon is up: the app only unregisters.
    @Test func aSuccessfulHandBackSaysTheCLIRunsAgain() async throws {
        let rig = Rig()
        rig.probe.script(.absent)
        let setup = rig.setup()
        guard case .success(let prepared) = await setup.prepare() else { Issue.record("prepare failed"); return }

        let outcome = await setup.activate(prepared, captured: nil, handBack: { Self.released(managedStopped: true) })

        guard case .handedBack(let failure) = outcome else { Issue.record("expected .handedBack, got \(outcome)"); return }
        #expect(failure.step == .hello)
    }

    @Test func aTakeoverRollbackHandsBackFirstThenUnregistersAndLeavesTheMarkerToLeo() async {
        let rig = await rollBackAfterTakeover(answering: Self.released(managedStopped: true))

        #expect(Array(rig.log.events.suffix(3)) == [.agent("register"), .run(["hand-back"]), .agent("unregister")])
        #expect(!rig.log.events.contains(.fs(.remove(Self.marker))))
    }

    @Test(arguments: [
        ("leo refused", LeoHandoverRun.failed(LeoJSONFailure(
            error: "bootstrap_failed", message: "not ready", step: "bootstrap", rolledBack: true, managedStopped: nil, warnings: []
        ))),
        ("no JSON", .malformed("exit 2")),
        ("ok, but the app's job wasn't stopped", released(managedStopped: false)),
    ])
    func aHandBackThatDidNotStopTheAppsJobKeepsTheMarkerAndRegistration(_: String, answer: LeoHandoverRun) async {
        let rig = await rollBackAfterTakeover(answering: answer)

        #expect(Array(rig.log.events.suffix(2)) == [.agent("register"), .run(["hand-back"])])
        guard case .ours = rig.writtenMarker() else { Issue.record("the marker went"); return }
    }

    /// leo booted the app's job out and couldn't restore the CLI: launchd
    /// starts the job again only after an unregister and a register.
    @Test func aFailedHandBackThatStoppedTheAppsJobRestartsItAndWaitsForHello() async {
        let answer = LeoHandoverRun.failed(LeoJSONFailure(
            error: "bootstrap_failed", message: "CLI job didn't load", step: "bootstrap", rolledBack: false, managedStopped: true, warnings: []
        ))
        let rig = await rollBackAfterTakeover(answering: answer, failRegister: true)

        #expect(Array(rig.log.events.suffix(4)) == [
            .agent("register"), .run(["hand-back"]), .agent("unregister"), .agent("register"),
        ])
        #expect(rig.probe.probes == 3)
        guard case .ours = rig.writtenMarker() else { Issue.record("the marker went"); return }
    }

    // MARK: already registered

    /// `SMAppService` answers this for a job it knows, even one launchd isn't
    /// running: never proof the daemon runs with the marker just written.
    @Test func anAlreadyRegisteredAgentIsRestartedNotTrusted() async {
        let rig = Rig()
        rig.agent.answerAlreadyRegisteredOnNextRegister()

        #expect(await rig.setup().run() == .ready(version: "0.57.0"))
        #expect(rig.log.events == Self.freshInstallOps + [.agent("register"), .agent("unregister"), .agent("register")])
    }

    @Test func anAlreadyRegisteredAgentThatWontRestartRollsBack() async {
        let rig = Rig()
        rig.agent.answerAlreadyRegisteredOnNextRegister()
        rig.agent.answerAlreadyRegisteredOnNextRegister()
        rig.agent.script(status: .enabled)

        guard case .failed(let failure) = await rig.setup().run() else { Issue.record("expected failure"); return }
        #expect(failure.step == .register)
        #expect(rig.probe.probes == 0)
    }

    // MARK: approval

    @Test func pendingApprovalKeepsTheMarkerAndRegistration() async throws {
        let rig = Rig()
        rig.agent.script(status: .requiresApproval)

        #expect(await rig.setup().run() == .awaitingApproval)

        #expect(rig.log.events == Self.freshInstallOps + [.agent("register")])
        #expect(rig.probe.probes == 0)
    }

    @Test func aRegisterThatThrowsWhileApprovalIsPendingIsNotAFailure() async throws {
        let rig = Rig()
        rig.agent.failNextRegister()
        rig.agent.script(status: .requiresApproval)

        #expect(await rig.setup().run() == .awaitingApproval)
        #expect(!rig.log.events.contains(.agent("unregister")))
    }

    @Test func afterApprovalItWaitsForHello() async throws {
        let rig = Rig()
        rig.agent.script(status: .enabled)

        #expect(await rig.setup().resumeAfterApproval() == .ready(version: "0.57.0"))
        #expect(rig.log.events.isEmpty)
    }

    @Test func stillAwaitingApprovalChangesNothing() async throws {
        let rig = Rig()
        rig.agent.script(status: .requiresApproval)

        #expect(await rig.setup().resumeAfterApproval() == .awaitingApproval)
        #expect(rig.log.events.isEmpty)
        #expect(rig.probe.probes == 0)
    }
}

/// The `hello` probe on `~/.leo/state/leo.sock`.
struct LeoDaemonProbeTests {
    private struct Transport: LeoDaemonTransport {
        let reply: @Sendable (LeoHTTPRequest, String) throws -> LeoHTTPResponse
        func send(_ request: LeoHTTPRequest, socketPath: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
            try reply(request, socketPath)
        }
    }

    private func probe(_ reply: @escaping @Sendable (LeoHTTPRequest, String) throws -> LeoHTTPResponse) async -> LeoDaemonProbeResult {
        await LeoDaemonProbe(socketPath: "/home/test/.leo/state/leo.sock", transport: Transport(reply: reply)).probe()
    }

    @Test func aHealthyDaemonIsLiveWithItsBareVersion() async {
        let result = await probe { request, socket in
            #expect(request == LeoHTTPRequest(method: "GET", path: "/health"))
            #expect(socket == "/home/test/.leo/state/leo.sock")
            return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":{"version":"0.57.0"}}"#.utf8))
        }
        #expect(result == .live(version: "0.57.0"))
    }

    @Test func aMissingSocketIsAbsent() async {
        #expect(await probe { _, path in throw LeoDaemonError.socketMissing(path: path) } == .absent)
    }

    @Test func aRefusedConnectionIsAbsent() async {
        #expect(await probe { _, _ in throw LeoDaemonError.transport("Connection refused") } == .absent)
    }

    @Test func aTimeoutIsUnresponsive() async {
        #expect(await probe { _, _ in throw LeoDaemonError.timeout } == .unresponsive)
    }

    @Test(arguments: [
        (200, "garbage"),
        (200, #"{"ok":false}"#),
        (500, #"{"ok":true,"data":{"version":"0.57.0"}}"#),
    ])
    func anAnswerThatIsNotAHealthyHelloIsUnresponsive(status: Int, body: String) async {
        #expect(await probe { _, _ in LeoHTTPResponse(status: status, body: Data(body.utf8)) } == .unresponsive)
    }

    // MARK: /health with the pid (B10)

    private func health(_ reply: @escaping @Sendable (LeoHTTPRequest, String) throws -> LeoHTTPResponse) async -> LeoDaemonHealthCheck {
        await LeoDaemonProbe(socketPath: "/home/test/.leo/state/leo.sock", transport: Transport(reply: reply)).health()
    }

    @Test(arguments: [
        (#"{"ok":true,"data":{"version":"0.56.1","ready":true,"pid":4242}}"#, Int32?.some(4242)),
        (#"{"ok":true,"data":{"version":"0.55.0"}}"#, nil),
    ])
    func healthReportsTheVersionAndPid(body: String, pid: Int32?) async {
        let result = await health { request, _ in
            #expect(request == LeoHTTPRequest(method: "GET", path: "/health"))
            return LeoHTTPResponse(status: 200, body: Data(body.utf8))
        }
        #expect(result == .answered(version: body.contains("0.56.1") ? "0.56.1" : "0.55.0", pid: pid))
    }

    @Test func healthWithNothingListeningIsAbsentAndATimeoutUnresponsive() async {
        #expect(await health { _, _ in throw LeoDaemonError.transport("Connection refused") } == .absent)
        #expect(await health { _, _ in throw LeoDaemonError.timeout } == .unresponsive)
        #expect(await health { _, _ in LeoHTTPResponse(status: 200, body: Data("garbage".utf8)) } == .unresponsive)
    }
}
