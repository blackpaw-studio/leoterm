import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B3: `leo service handover` argv and JSON (contract C6, round 3), and the
/// takeover sequence around it, every seam a fake.
struct LeoHandoverTests {
    static let bundled = "/Applications/Leo.app/Contents/Helpers/leo"
    static let toApp = [bundled, "service", "handover", "--to-app", "--label", "studio.blackpaw.leo.daemon", "--json"]
    static let toCLI = [bundled, "service", "handover", "--to-cli", "--json"]
    static let plistBackup = "/home/test/Library/LaunchAgents/com.blackpaw.leo.plist.handed-over"

    /// leo main's `--to-app` success: no `step`, `rolled_back` or `managed_stopped`.
    static let okJSON = #"""
    {"ok":true,"previous_label":"com.blackpaw.leo","env":{"PATH":"/opt/homebrew/bin:/usr/bin","GITHUB_TOKEN":"t"},
     "plist_backup":"/home/test/Library/LaunchAgents/com.blackpaw.leo.plist.handed-over","warnings":["drained 2 agents"]}
    """#
    /// A successful `--to-cli` booted the app's job out (round 4).
    static let toCLIOKJSON = #"""
    {"ok":true,"previous_label":"studio.blackpaw.leo.daemon","managed_stopped":true,
     "plist_backup":"/home/test/Library/LaunchAgents/com.blackpaw.leo.plist.handed-over"}
    """#

    private func run(_ reply: LeoScriptedRunner.Reply, toCLI: Bool = false) async -> (LeoHandoverRun, LeoScriptedRunner) {
        let runner = LeoScriptedRunner(log: LeoManagedEventLog())
        runner.on(toCLI ? Self.toCLI : Self.toApp, reply)
        let handover = LeoHandover(runner: runner, bundledLeo: Self.bundled)
        let result = toCLI ? await handover.toCLI() : await handover.toApp(label: "studio.blackpaw.leo.daemon")
        return (result, runner)
    }

    @Test func toAppRunsTheBundledLeoByPathWithTheAppLabelAndNoShortDeadline() async {
        let (_, runner) = await run(.exit(0, stdout: Self.okJSON))
        #expect(runner.timeouts.keys.map { $0 } == [Self.toApp])
        #expect((runner.timeouts[Self.toApp] ?? 0) > 10 * 60)
    }

    @Test func toCLIRunsTheBundledLeoByPath() async {
        let (_, runner) = await run(.exit(0, stdout: Self.toCLIOKJSON), toCLI: true)
        #expect(runner.timeouts.keys.map { $0 } == [Self.toCLI])
        #expect((runner.timeouts[Self.toCLI] ?? 0) > 10 * 60)
    }

    @Test func decodesEverySuccessField() async {
        let (result, _) = await run(.exit(0, stdout: Self.okJSON))
        #expect(result == .succeeded(LeoHandoverResult(
            previousLabel: "com.blackpaw.leo",
            env: ["PATH": "/opt/homebrew/bin:/usr/bin", "GITHUB_TOKEN": "t"],
            plistBackup: Self.plistBackup, managedStopped: false, warnings: ["drained 2 agents"]
        )))
    }

    @Test func aSuccessfulReleaseSaysTheAppsJobStopped() async {
        let (result, _) = await run(.exit(0, stdout: Self.toCLIOKJSON), toCLI: true)
        guard case .succeeded(let decoded) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(decoded.managedStopped)
    }

    @Test func aMinimalSuccessHasNoWarnings() async {
        let (result, _) = await run(.exit(0, stdout: #"{"ok":true}"#))
        guard case .succeeded(let decoded) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(decoded.warnings.isEmpty)
        #expect(decoded.env == nil)
        #expect(!decoded.managedStopped)
    }

    @Test func aStepFailureKeepsItsStepMessageAndRollback() async {
        let json = #"{"ok":false,"step":"bootout","error":"bootout_failed","message":"launchctl said no","rolled_back":true}"#
        let (result, _) = await run(.exit(1, stdout: json, stderr: "log noise"))
        #expect(result == .failed(LeoJSONFailure(
            error: "bootout_failed", message: "launchctl said no", step: "bootout", rolledBack: true, managedStopped: nil, warnings: []
        )))
    }

    /// The JSON rule's envelope: `{error, message?}` and nothing else.
    @Test(arguments: [
        (#"{"error":"invalid_args","message":"pass exactly one of --to-app (with --label) or --to-cli"}"#, "invalid_args"),
        (#"{"error":"not_permitted","message":"agents may not hand over"}"#, "not_permitted"),
        (#"{"step":"preflight","error":"no_launchd_job","message":"started by hand?"}"#, "no_launchd_job"),
    ])
    func anErrorOnlyFailureReachesItsCode(json: String, code: String) async {
        let (result, _) = await run(.exit(1, stdout: json))
        guard case .failed(let decoded) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(decoded.error == code)
    }

    @Test(arguments: [
        LeoScriptedRunner.Reply.exit(0, stdout: "not json"),
        .exit(1, stdout: ""),
        .exit(0, stdout: #"{"ok":false,"error":"x"}"#),
        .exit(0, stdout: #"{"error":"x"}"#),
        .exit(1, stdout: #"{"ok":true}"#),
        .exit(1, stdout: #"{"message":"no code"}"#),
        .exit(1, stdout: #"{"error":""}"#),
        .exit(0, stdout: #"{"step":"done"}"#),
        .error(LeoDaemonError.timeout),
    ])
    func anythingButAConsistentAnswerIsMalformed(reply: LeoScriptedRunner.Reply) async {
        let (result, _) = await run(reply)
        guard case .malformed = result else { Issue.record("expected malformed, got \(result)"); return }
    }
}

struct LeoTakeoverTests {
    static let label = "studio.blackpaw.leo.daemon"
    static let marker = "/home/test/.leo/state/managed.json"
    static let brewTmux = "/opt/homebrew/bin/tmux"
    static let cellarTmux = "/opt/homebrew/Cellar/tmux/3.6a/bin/tmux"
    static let display = [brewTmux, "-L", "leo", "display", "-p", "#{version}"]
    static let preflight = "/home/test/.leo/state/managed.json.preflight"
    /// A 0600 file made and removed beside the marker, before the handover.
    static let markerPreflight: [LeoManagedEvent] = [
        .fs(.createDirectory("/home/test/.leo/state", mode: 0o700)),
        .fs(.write("/home/test/.leo/state/.managed.json.preflight.t2.tmp", mode: 0o600)),
        .fs(.rename("/home/test/.leo/state/.managed.json.preflight.t2.tmp", preflight)),
        .fs(.remove(preflight)),
    ]

    struct Rig {
        let base = LeoManagedSetupTests.Rig()
        var log: LeoManagedEventLog { base.log }
        var runner: LeoScriptedRunner { base.runner }
        var fileSystem: LeoInMemoryFileSystem { base.fileSystem }

        init() {
            base.runner.on(LeoHandoverTests.toApp, .exit(0, stdout: LeoHandoverTests.okJSON))
            base.runner.on(LeoHandoverTests.toCLI, .exit(0, stdout: LeoHandoverTests.toCLIOKJSON))
            // No `-L leo` server unless a test says so.
            base.runner.on(LeoTakeoverTests.display, .exit(1, stderr: "no server running on /tmp/tmux-501/leo"))
            base.fileSystem.addFile(LeoTakeoverTests.cellarTmux, "tmux-3.6a", mode: 0o555)
            base.fileSystem.addSymlink(LeoTakeoverTests.brewTmux, to: "../Cellar/tmux/3.6a/bin/tmux")
        }

        func takeover() -> LeoTakeover {
            let setup = base.setup()
            return LeoTakeover(
                handover: LeoHandover(runner: base.runner, bundledLeo: LeoHandoverTests.bundled),
                setup: setup,
                runner: base.runner,
                loginPath: { "/usr/bin:/bin" },
                label: LeoTakeoverTests.label
            )
        }

        /// Everything after the setup's own preparation.
        func eventsAfterPrepare() -> [LeoManagedEvent] {
            Array(log.events.dropFirst(LeoManagedSetupTests.freshInstallOps.count - 3))
        }

        /// Everything after the preparation and the marker write check.
        func eventsAfterPreflight() -> [LeoManagedEvent] {
            Array(eventsAfterPrepare().dropFirst(LeoTakeoverTests.markerPreflight.count))
        }
    }

    // MARK: success

    @Test func anOKHandoverRunsSetupWithTheCapturedEnvironment() async throws {
        let rig = Rig()

        let outcome = await rig.takeover().run()

        #expect(outcome == .managed(version: "0.57.0", warnings: ["drained 2 agents"]))
        #expect(rig.eventsAfterPrepare() == Self.markerPreflight + [
            .run(Self.display),
            .run(LeoHandoverTests.toApp),
            .fs(.write("/home/test/.leo/state/.managed.json.t3.tmp", mode: 0o600)),
            .fs(.rename("/home/test/.leo/state/.managed.json.t3.tmp", Self.marker)),
            .agent("register"),
        ])
        guard case .ours(let marker) = rig.base.writtenMarker() else { Issue.record("no marker"); return }
        #expect(marker.env?["GITHUB_TOKEN"] == "t")
        #expect(marker.env?["PATH"] == "/home/test/.local/bin:/opt/homebrew/bin:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func preparationRunsBeforeTheHandoverAndAFailureThereHandsNothingOver() async throws {
        let rig = Rig()
        rig.runner.on([LeoManagedSetupTests.bundledTmux, "-V"], .exit(1))

        guard case .preparationFailed(let failure) = await rig.takeover().run() else { Issue.record("expected preparation failure"); return }
        #expect(failure.step == .tmux)
        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toApp)))
    }

    @Test func pendingApprovalAfterAnOKHandoverIsNotAFailure() async throws {
        let rig = Rig()
        rig.base.agent.script(status: .requiresApproval)

        #expect(await rig.takeover().run() == .awaitingApproval(warnings: ["drained 2 agents"]))
        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toCLI)))
    }

    // MARK: handover failures write nothing

    @Test func noLaunchdJobMeansItCannotTakeOverAutomatically() async throws {
        let rig = Rig()
        let json = #"{"ok":false,"step":"preflight","error":"no_launchd_job","message":"daemon was not started by launchd"}"#
        rig.runner.on(LeoHandoverTests.toApp, .exit(1, stdout: json))

        let outcome = await rig.takeover().run()

        #expect(outcome == .cannotTakeOver)
        #expect(LeoTakeoverAnswer.remembered(after: outcome) == .unavailable)
        #expect(Array(rig.eventsAfterPrepare().suffix(1)) == [.run(LeoHandoverTests.toApp)])
        #expect(rig.base.writtenMarker() == .absent)
    }

    @Test func aRolledBackHandoverKeepsTheCLIDaemonAndWritesNothing() async throws {
        let rig = Rig()
        let json = #"{"ok":false,"step":"bootout","error":"bootout_failed","message":"no","rolled_back":true}"#
        rig.runner.on(LeoHandoverTests.toApp, .exit(1, stdout: json))

        let outcome = await rig.takeover().run()

        #expect(outcome == .handoverFailed(step: "bootout", message: "no", rolledBack: true))
        #expect(LeoTakeoverAnswer.remembered(after: outcome) == nil)
        #expect(Array(rig.eventsAfterPrepare().suffix(1)) == [.run(LeoHandoverTests.toApp)])
    }

    @Test func aFailedRollbackIsReportedAndNeverRecoveredWithToCLI() async throws {
        let rig = Rig()
        let json = #"{"ok":false,"step":"bootstrap","error":"bootstrap_failed","message":"stuck","rolled_back":false}"#
        rig.runner.on(LeoHandoverTests.toApp, .exit(1, stdout: json))

        let outcome = await rig.takeover().run()

        #expect(outcome == .handoverFailed(step: "bootstrap", message: "stuck", rolledBack: false))
        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toCLI)))
        #expect(rig.base.writtenMarker() == .absent)
    }

    @Test func malformedOutputKeepsTheCLIDaemonAndWritesNothing() async throws {
        let rig = Rig()
        rig.runner.on(LeoHandoverTests.toApp, .exit(0, stdout: "Draining agents…"))

        guard case .handoverFailed(nil, _, nil) = await rig.takeover().run() else { Issue.record("expected an unknown failure"); return }
        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toCLI)))
        #expect(rig.base.writtenMarker() == .absent)
    }

    // MARK: the marker must be writable before the handover

    /// After `--to-app` the CLI daemon is down until the marker is written.
    @Test func anUnwritableMarkerStopsTheTakeoverBeforeTheHandover() async {
        let rig = Rig()
        rig.fileSystem.failNext("write", at: Self.preflight, code: EACCES)

        guard case .preparationFailed(let failure) = await rig.takeover().run() else { Issue.record("expected preparation failure"); return }

        #expect(failure.step == .marker)
        #expect(!rig.log.events.contains(.run(LeoHandoverTests.toApp)))
        #expect(!rig.log.events.contains { if case .agent = $0 { true } else { false } })
    }

    // MARK: setup failure after an OK handover

    @Test func aFailedRegisterAfterHandoverHandsBackToTheCLIThenUnregisters() async throws {
        let rig = Rig()
        rig.base.agent.failNextRegister()
        rig.base.agent.script(status: .notRegistered)

        guard case .setupFailed(let failure, cliRestored: true) = await rig.takeover().run() else { Issue.record("expected setup failure"); return }
        #expect(failure.step == .register)
        #expect(Array(rig.log.events.suffix(3)) == [
            .agent("register"),
            .run(LeoHandoverTests.toCLI),
            .agent("unregister"),
        ])
        // leo moves managed.json aside and deletes it once the CLI daemon is up.
        #expect(!rig.log.events.contains(.fs(.remove(Self.marker))))
    }

    @Test func aFailedHandBackIsReportedAndKeepsRecoveryState() async throws {
        let rig = Rig()
        rig.base.probe.script(.absent)
        let json = #"{"ok":false,"step":"ready","error":"not_ready","message":"CLI daemon didn't answer","rolled_back":true}"#
        rig.runner.on(LeoHandoverTests.toCLI, .exit(1, stdout: json))

        guard case .setupFailed(let failure, cliRestored: false) = await rig.takeover().run() else { Issue.record("expected setup failure"); return }
        #expect(failure.step == .hello)
        #expect(!rig.log.events.contains(.agent("unregister")))
        guard case .ours = rig.base.writtenMarker() else { Issue.record("the marker went"); return }
    }

    // MARK: the running tmux server's version

    @Test func aRunningServersVersionIsCopiedFromTheResolvedCLITmuxBeforeHandover() async throws {
        let rig = Rig()
        rig.runner.on(Self.display, .exit(0, stdout: "3.6a\n"))
        rig.runner.on([Self.brewTmux, "-V"], .exit(0, stdout: "tmux 3.6a\n"))

        _ = await rig.takeover().run()

        let temp = "/home/test/.leo/app/tmux/3.6a/.tmux.c2.tmp"
        #expect(Array(rig.eventsAfterPreflight().prefix(7)) == [
            .run(Self.display),
            .run([Self.brewTmux, "-V"]),
            .fs(.createDirectory("/home/test/.leo/app/tmux/3.6a", mode: 0o755)),
            .fs(.copy(Self.cellarTmux, temp)),
            .fs(.chmod(temp, mode: 0o755)),
            .fs(.moveNoReplace(temp, "/home/test/.leo/app/tmux/3.6a/tmux")),
            .run(LeoHandoverTests.toApp),
        ])
        #expect(rig.fileSystem.contents(of: "/home/test/.leo/app/tmux/3.6a/tmux") == "tmux-3.6a")
    }

    @Test func theCLIPlistPathIsSearchedFirst() async throws {
        let rig = Rig()
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.blackpaw.leo", "EnvironmentVariables": ["PATH": "/custom/bin:/usr/bin"]],
            format: .xml, options: 0
        )
        rig.fileSystem.addFile("/home/test/Library/LaunchAgents/com.blackpaw.leo.plist", plist)
        rig.fileSystem.addFile("/custom/bin/tmux", "custom", mode: 0o755)
        let display = ["/custom/bin/tmux", "-L", "leo", "display", "-p", "#{version}"]
        rig.runner.on(display, .exit(1))

        _ = await rig.takeover().run()

        #expect(rig.log.events.contains(.run(display)))
        #expect(!rig.log.events.contains(.run(Self.display)))
    }

    @Test func aServerOnAVersionAlreadyCopiedNeedsNothing() async throws {
        let rig = Rig()
        rig.runner.on(Self.display, .exit(0, stdout: "3.6b\n"))

        _ = await rig.takeover().run()

        #expect(Array(rig.eventsAfterPreflight().prefix(2)) == [.run(Self.display), .run(LeoHandoverTests.toApp)])
    }

    @Test func noBinaryForTheServersVersionIsAWarningNotABlock() async throws {
        let rig = Rig()
        rig.runner.on(Self.display, .exit(0, stdout: "3.5a\n"))
        rig.runner.on([Self.brewTmux, "-V"], .exit(0, stdout: "tmux 3.6a\n"))

        guard case .managed(_, let warnings) = await rig.takeover().run() else { Issue.record("expected managed"); return }
        #expect(warnings.first?.contains("3.5a") == true)
        #expect(rig.fileSystem.kind(at: URL(fileURLWithPath: "/home/test/.leo/app/tmux/3.5a")) == .absent)
    }

    // MARK: the one-time offer

    @Test func theAnswerIsRememberedAndClearedThroughDefaults() {
        let store = LeoTakeoverStore(defaults: LeoInMemoryDefaults())
        #expect(store.answer == .notAsked)
        store.answer = .declined
        #expect(store.answer == .declined)
        store.clear()
        #expect(store.answer == .notAsked)
    }
}
