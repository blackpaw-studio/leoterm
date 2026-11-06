import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-339: a managed install whose `leo.yaml` has no `web:` section gets the
/// loopback web API through the bundled `leo web enable`, once, and nothing
/// else is ever rewritten. Every seam is a fake; no real `~/.leo` is touched.
@MainActor struct LeoManagedWebAPITests {
    typealias Rig = LeoRuntimeManagedStartTests.Rig

    static let helper = LeoManagedSetupTests.helper
    static let config = "/home/test/.leo/leo.yaml"
    static let enable = [helper, "web", "enable", "--bind", "127.0.0.1", "--config", config, "--json"]
    static let changedAndRestarted = #"{"ok":true,"changed":true,"restarted":true}"#
    /// Shaped like the laptop's config: no `web`.
    static let laptopConfig = """
    defaults:
      model: sonnet
    templates:
      assistant:
        model: opus
    tasks: []
    """

    final class Reconnects {
        var count = 0
    }

    /// A managed 0.57.0 daemon, our marker, a `leo.yaml`; `run()` already done.
    private func managed(
        yaml: String? = laptopConfig, reply: LeoScriptedRunner.Reply = .exit(0, stdout: changedAndRestarted)
    ) async throws -> (Rig, LeoManagedStartup, Reconnects) {
        let rig = Rig()
        try rig.writeOurMarker()
        if let yaml { rig.base.fileSystem.addFile(Self.config, yaml, mode: 0o600) }
        rig.base.runner.on(Self.enable, reply)
        rig.base.probe.script(.live(version: "0.57.0"))
        let reconnects = Reconnects()
        let startup = rig.startup()
        startup.daemonChanged = { reconnects.count += 1 }
        await startup.run()
        return (rig, startup, reconnects)
    }

    private func enableRuns(_ rig: Rig) -> Int { rig.count(.run(Self.enable)) }

    @Test func managedConfigWithoutWebTurnsOnLoopbackAPI() async throws {
        let (rig, startup, reconnects) = try await managed()
        rig.base.probe.script(.live(version: "0.57.1"))

        await startup.ensureWebAPI()

        #expect(rig.log.events.contains(.run(Self.enable)))
        #expect(enableRuns(rig) == 1)
        #expect(rig.base.runner.timeouts[Self.enable] == LeoHandover.timeout)
        #expect(startup.status == .managed(version: "0.57.1"))
        #expect(reconnects.count == 1)
        #expect(startup.presentation.banner == nil)
    }

    @Test func onceTheHelperHasWrittenWebTheNextCallSkips() async throws {
        // The helper wrote it: the next launch reads `web:` and skips.
        let (rig, startup, _) = try await managed()
        await startup.ensureWebAPI()
        rig.base.fileSystem.addFile(Self.config, Self.laptopConfig + "\nweb:\n  enabled: true\n", mode: 0o600)

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 1)
    }

    @Test(arguments: [
        "web:\n  enabled: false\n",
        "defaults: {}\nweb: {}\n",
        "\"web\":\n  enabled: true\n",
        "web:\n  port: 9000\n",
    ])
    func anExistingWebSectionIsNeverTouched(yaml: String) async throws {
        let (rig, startup, reconnects) = try await managed(yaml: yaml)

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
        #expect(reconnects.count == 0)
    }

    @Test(arguments: ["{defaults: {}}\n", "defaults: {}\n---\ntasks: []\n", "defaults: {}\n<<: *base\n"])
    func anAmbiguousConfigIsLeftAlone(yaml: String) async throws {
        let (rig, startup, _) = try await managed(yaml: yaml)

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
    }

    @Test func aMissingConfigIsLeftForTheDaemonToCreate() async throws {
        let (rig, startup, _) = try await managed(yaml: nil)

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
    }

    @Test func aSymlinkedConfigIsNeverFollowed() async throws {
        let (rig, startup, _) = try await managed(yaml: nil)
        rig.base.fileSystem.addSymlink(Self.config, to: "/dotfiles/leo.yaml")

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
    }

    @Test func aMarkerThatIsNotOursRunsNothing() async throws {
        let rig = Rig()
        rig.base.fileSystem.addFile(Self.config, Self.laptopConfig, mode: 0o600)
        rig.base.probe.script(.live(version: "0.57.0"))
        rig.base.agent.script(status: .notRegistered)
        let startup = rig.startup()
        await startup.run()

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
    }

    @Test func aCLIDaemonRunsNothing() async throws {
        let rig = Rig()
        rig.base.fileSystem.addFile(Self.config, Self.laptopConfig, mode: 0o600)
        rig.base.agent.script(status: .notRegistered)
        rig.base.probe.script(.live(version: "0.55.0"))
        let startup = rig.startup()
        await startup.run()
        guard case .usingCLI = startup.status else { Issue.record("expected usingCLI, got \(startup.status)"); return }

        await startup.ensureWebAPI()

        #expect(enableRuns(rig) == 0)
    }

    @Test func aHelperThatSavedButDidNotRestartDoesNotReconnect() async throws {
        let (rig, startup, reconnects) = try await managed(reply: .exit(0, stdout: #"{"ok":true,"changed":true,"restarted":false}"#))
        let probesBefore = rig.base.probe.probes

        await startup.ensureWebAPI()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 0)
        #expect(rig.base.probe.probes == probesBefore)
    }

    @Test func aDrainTimeoutLeavesARestartNotice() async throws {
        let (_, startup, reconnects) = try await managed(
            reply: .exit(1, stdout: #"{"error":"drain_timeout","message":"2 agents still busy after 10m0s"}"#)
        )

        await startup.ensureWebAPI()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 0)
        let banner = startup.presentation.banner
        #expect(banner?.title == "Leo’s web API is saved but not on yet")
        #expect(banner?.detail.contains("Restart Daemon") == true)
    }

    @Test(arguments: [
        LeoScriptedRunner.Reply.exit(2, stdout: #"{"error":"config_invalid","message":"web.port: out of range"}"#),
        .exit(1, stdout: #"{"error":"not_registered","message":"no job studio.blackpaw.leo.daemon"}"#),
        .exit(0, stdout: "not json"),
        .error(LeoRestartTestError.boom),
    ])
    func anyOtherAnswerShowsANoticeWithTheAdvice(reply: LeoScriptedRunner.Reply) async throws {
        let (_, startup, reconnects) = try await managed(reply: reply)

        await startup.ensureWebAPI()

        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(reconnects.count == 0)
        let banner = startup.presentation.banner
        #expect(banner?.title == "Leo couldn’t turn on its web API")
        #expect(banner?.detail.contains("leo web enable") == true)
    }

    @Test func aDaemonThatNeverComesBackIsReported() async throws {
        let (rig, startup, reconnects) = try await managed()
        rig.base.probe.script(.absent)

        await startup.ensureWebAPI()

        guard case .failed = startup.status else { Issue.record("expected failure, got \(startup.status)"); return }
        #expect(reconnects.count == 0)
    }
}
