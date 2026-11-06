import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-341: a managed install whose `leo.yaml` sets no dispatch viewer
/// placement gets `placement: window`, checked by the bundled leo before it
/// replaces the file; an explicit value or anything ambiguous is left alone.
/// Every seam is a fake; no real `~/.leo` is touched.
@MainActor struct LeoManagedViewerPlacementTests {
    typealias Rig = LeoRuntimeManagedStartTests.Rig

    static let helper = LeoManagedSetupTests.helper
    static let config = "/home/test/.leo/leo.yaml"
    static let configURL = URL(fileURLWithPath: config)
    /// The validation copy, named by the startup's first token.
    static let candidate = "/home/test/.leo/.leo.yaml.c1.tmp"
    static let validate = [helper, "config", "show", "--json", "--config", candidate]
    /// What `config show --json` prints: secrets included, so it's never kept.
    static let shown = #"{"Defaults":{"Model":"sonnet"},"Web":{"Token":"secret"}}"#
    /// Shaped like the laptop's config: no `dispatch` under `defaults`.
    static let laptopConfig = """
    defaults:
      model: sonnet
    templates:
      assistant:
        model: opus
    tasks: {}

    """
    static let laptopConfigWithWindow = """
    defaults:
      dispatch:
        viewer:
          placement: window
      model: sonnet
    templates:
      assistant:
        model: opus
    tasks: {}

    """

    /// A managed 0.57.0 daemon, our marker, a 0600 `leo.yaml`; `run()` already
    /// done and its log cleared, so the log holds only this step's work.
    private func managed(
        yaml: String = laptopConfig, reply: LeoScriptedRunner.Reply = .exit(0, stdout: shown)
    ) async throws -> (Rig, LeoManagedStartup) {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.fileSystem.addFile(Self.config, yaml, mode: 0o600)
        rig.base.runner.on(Self.validate, reply)
        rig.base.probe.script(.live(version: "0.57.0"))
        let startup = rig.startup()
        await startup.run()
        #expect(startup.status == .managed(version: "0.57.0"))
        rig.log.clear()
        rig.base.fileSystem.clearLog()
        return (rig, startup)
    }

    private func runs(_ rig: Rig) -> [[String]] {
        rig.log.events.compactMap { if case let .run(argv) = $0 { argv } else { nil } }
    }

    @Test func managedConfigWithoutPlacementGetsWindow() async throws {
        let (rig, startup) = try await managed()

        await startup.ensureViewerPlacement()

        let fileSystem = rig.base.fileSystem
        #expect(fileSystem.contents(of: Self.config) == Self.laptopConfigWithWindow)
        #expect(fileSystem.mode(at: Self.configURL) == 0o600)
        #expect(runs(rig) == [Self.validate])
        #expect(fileSystem.kind(at: URL(fileURLWithPath: Self.candidate)) == .absent)
        #expect(startup.status == .managed(version: "0.57.0"))
        #expect(startup.presentation.banner == nil)
    }

    @Test func onceWrittenTheNextLaunchLeavesItAlone() async throws {
        let (rig, startup) = try await managed()
        await startup.ensureViewerPlacement()
        rig.log.clear()
        rig.base.fileSystem.clearLog()

        await startup.ensureViewerPlacement()

        #expect(rig.base.fileSystem.contents(of: Self.config) == Self.laptopConfigWithWindow)
        #expect(runs(rig).isEmpty)
        #expect(rig.base.fileSystem.ops.isEmpty)
    }

    @Test(arguments: [
        "defaults:\n  dispatch:\n    viewer:\n      placement: pane\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: \"\"\n",
    ])
    func explicitPlacementIsNeverRewritten(yaml: String) async throws {
        let (rig, startup) = try await managed(yaml: yaml)

        await startup.ensureViewerPlacement()

        #expect(rig.base.fileSystem.contents(of: Self.config) == yaml)
        #expect(runs(rig).isEmpty)
        #expect(rig.base.fileSystem.ops.isEmpty)
    }

    enum NotOurs: CaseIterable, Sendable {
        case noMarker, foreignMarker, awaitingApproval
    }

    @Test(arguments: NotOurs.allCases)
    func notOursOrUnmanagedIsUntouched(state: NotOurs) async throws {
        let rig = Rig()
        rig.base.fileSystem.addFile(Self.config, Self.laptopConfig, mode: 0o600)
        rig.base.runner.on(Self.validate, .exit(0, stdout: Self.shown))
        rig.base.probe.script(.live(version: "0.57.0"))
        switch state {
        case .noMarker: rig.base.agent.script(status: .notRegistered)
        case .foreignMarker, .awaitingApproval: try rig.writeOurMarker()
        }
        if state == .awaitingApproval { rig.base.agent.script(status: .requiresApproval) }
        let startup = rig.startup()
        await startup.run()
        if state == .foreignMarker {
            // Managed at launch, then another app's marker replaced ours.
            #expect(startup.status == .managed(version: "0.57.0"))
            let theirs = LeoManagedMarker(
                bundleID: "com.example.other", launchdLabel: "com.example.other.daemon",
                selfPath: "/elsewhere/leo", tmuxPath: "/elsewhere/tmux", env: [:]
            )
            rig.base.fileSystem.addFile(LeoManagedSetupTests.marker, try theirs.encoded(), mode: 0o600)
        }
        rig.log.clear()
        rig.base.fileSystem.clearLog()

        await startup.ensureViewerPlacement()

        #expect(rig.base.fileSystem.contents(of: Self.config) == Self.laptopConfig)
        #expect(runs(rig).isEmpty)
        #expect(rig.base.fileSystem.ops.isEmpty)
    }

    @Test(arguments: [
        LeoScriptedRunner.Reply.exit(1, stderr: "defaults.dispatch.viewer.placement: invalid"),
        .error(LeoRestartTestError.boom),
    ])
    func invalidCandidateLeavesFileAlone(reply: LeoScriptedRunner.Reply) async throws {
        let (rig, startup) = try await managed(reply: reply)

        await startup.ensureViewerPlacement()

        let fileSystem = rig.base.fileSystem
        #expect(fileSystem.contents(of: Self.config) == Self.laptopConfig)
        #expect(runs(rig) == [Self.validate])
        #expect(fileSystem.kind(at: URL(fileURLWithPath: Self.candidate)) == .absent)
        #expect(!fileSystem.ops.contains { if case let .rename(_, to) = $0 { to == Self.config } else { false } })
        #expect(startup.presentation.banner == nil)
    }

    @Test func fileChangedDuringValidationIsSkipped() async throws {
        let (rig, startup) = try await managed()
        let fileSystem = rig.base.fileSystem
        let saved = Self.laptopConfig + "web:\n  enabled: true\n"
        rig.base.runner.whileRunning(Self.validate) { fileSystem.addFile(Self.config, saved, mode: 0o600) }

        await startup.ensureViewerPlacement()

        #expect(fileSystem.contents(of: Self.config) == saved)
        #expect(runs(rig) == [Self.validate])
        #expect(fileSystem.kind(at: URL(fileURLWithPath: Self.candidate)) == .absent)
        #expect(startup.presentation.banner == nil)
    }

    @Test func aConfigThatIsNotUTF8IsLeftAlone() async throws {
        let (rig, startup) = try await managed()
        let latin1 = Data("defaults:\n  model: caf".utf8) + Data([0xE9, 0x0A])
        rig.base.fileSystem.addFile(Self.config, latin1, mode: 0o600)

        await startup.ensureViewerPlacement()

        #expect(try rig.base.fileSystem.read(Self.configURL) == latin1)
        #expect(runs(rig).isEmpty)
    }
}
