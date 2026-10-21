import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B4: Release to CLI runs `handover --to-cli` first and unregisters only
/// after leo says ok; a failure leaves the user's `leo` command as it was.
struct LeoReleaseToCLITests {
    static let localBin = "/home/test/.local/bin/leo"
    static let backup = "/home/test/.local/bin/leo.pre-leoapp"
    static let selfLink = "/home/test/.leo/app/bin/leo"
    static let marker = "/home/test/.leo/state/managed.json"
    static let toCLI = LeoHandoverTests.toCLI

    struct Rig {
        let log = LeoManagedEventLog()
        let fileSystem = LeoInMemoryFileSystem()
        let runner: LeoScriptedRunner
        let agent: LeoFakeLaunchAgent

        init(reply: LeoScriptedRunner.Reply = .exit(0, stdout: #"{"ok":true,"warnings":["drained 1 agent"]}"#)) {
            runner = LeoScriptedRunner(log: log)
            agent = LeoFakeLaunchAgent(log: log, status: .enabled)
            runner.on(LeoReleaseToCLITests.toCLI, reply)
            fileSystem.addFile(LeoReleaseToCLITests.marker, "{}", mode: 0o600)
            let log = log
            fileSystem.observe { log.append(.fs($0)) }
        }

        func run(confirmed: Bool = true) async -> LeoReleaseToCLI.Outcome {
            await LeoReleaseToCLI(
                handover: LeoHandover(runner: runner, bundledLeo: LeoHandoverTests.bundled),
                agent: agent,
                paths: LeoManagedSetupTests.paths,
                fileSystem: fileSystem
            ).run(confirm: { confirmed })
        }
    }

    @Test func declinedDoesNothing() async {
        let rig = Rig()
        #expect(await rig.run(confirmed: false) == .declined)
        #expect(rig.log.events.isEmpty)
    }

    @Test func handsOverFirstThenDropsTheMarkerThenUnregisters() async {
        let rig = Rig()

        #expect(await rig.run() == .released(warnings: ["drained 1 agent"]))

        #expect(rig.log.events == [
            .run(Self.toCLI),
            .fs(.remove(Self.marker)),
            .agent("unregister"),
        ])
    }

    @Test func ourCommandLinkGivesWayToTheBackupBeforeTheHandover() async {
        let rig = Rig()
        rig.fileSystem.addSymlink(Self.localBin, to: Self.selfLink)
        rig.fileSystem.addFile(Self.backup, "curl-installed leo", mode: 0o755)

        _ = await rig.run()

        #expect(Array(rig.log.events.prefix(2)) == [.fs(.move(Self.backup, Self.localBin)), .run(Self.toCLI)])
        #expect(rig.fileSystem.contents(of: Self.localBin) == "curl-installed leo")
    }

    @Test(arguments: [
        ("our link, no backup", true, false),
        ("someone else's file, with a backup", false, true),
    ])
    func otherwiseTheCommandIsLeftAlone(_: String, ourLink: Bool, hasBackup: Bool) async {
        let rig = Rig()
        if ourLink { rig.fileSystem.addSymlink(Self.localBin, to: Self.selfLink) } else { rig.fileSystem.addFile(Self.localBin, "x") }
        if hasBackup { rig.fileSystem.addFile(Self.backup, "old") }

        _ = await rig.run()

        #expect(rig.log.events.first == .run(Self.toCLI))
    }

    @Test func aFailedUnregisterStillReleasesAndIsRecoveredNextLaunch() async {
        let rig = Rig()
        rig.agent.failNextUnregister()

        guard case .released(let warnings) = await rig.run() else { Issue.record("expected released"); return }
        #expect(warnings.count == 2)
    }

    @Test func leoRolledBackSoTheAgentIsRegisteredAgainAndTheCommandRestored() async {
        let json = #"{"ok":false,"step":"bootstrap","error":"bootstrap_failed","message":"CLI daemon didn't start","managed_stopped":true}"#
        let rig = Rig(reply: .exit(1, stdout: json))
        rig.fileSystem.addSymlink(Self.localBin, to: Self.selfLink)
        rig.fileSystem.addFile(Self.backup, "curl-installed leo", mode: 0o755)

        #expect(await rig.run() == .failed(message: "CLI daemon didn't start", reRegistered: true))

        #expect(rig.log.events == [
            .fs(.move(Self.backup, Self.localBin)),
            .run(Self.toCLI),
            .fs(.moveNoReplace(Self.localBin, Self.backup)),
            .fs(.symlink(Self.localBin, target: Self.selfLink)),
            .agent("register"),
        ])
        #expect(rig.fileSystem.kind(at: URL(fileURLWithPath: Self.marker)) == .file)
    }

    @Test(arguments: [
        LeoScriptedRunner.Reply.exit(1, stdout: #"{"ok":false,"error":"drain_timeout","managed_stopped":false}"#),
        .exit(0, stdout: "garbage"),
        .error(LeoDaemonError.timeout),
    ])
    func aFailureThatChangedNothingLeavesStateIntact(reply: LeoScriptedRunner.Reply) async {
        let rig = Rig(reply: reply)
        rig.fileSystem.addSymlink(Self.localBin, to: Self.selfLink)
        rig.fileSystem.addFile(Self.backup, "curl-installed leo", mode: 0o755)

        guard case .failed(_, reRegistered: false) = await rig.run() else { Issue.record("expected failure"); return }

        #expect(!rig.log.events.contains { if case .agent = $0 { true } else { false } })
        #expect(rig.fileSystem.kind(at: URL(fileURLWithPath: Self.localBin)) == .symlink(target: Self.selfLink))
        #expect(rig.fileSystem.contents(of: Self.backup) == "curl-installed leo")
        #expect(rig.fileSystem.kind(at: URL(fileURLWithPath: Self.marker)) == .file)
    }
}
