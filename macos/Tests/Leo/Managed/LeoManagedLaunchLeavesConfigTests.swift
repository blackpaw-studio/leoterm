import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-364: the bundled leo (0.76.0+) defaults dispatch viewers to windows
/// itself, so the app's post-launch steps never edit a managed `leo.yaml` for
/// viewer placement. Every seam is a fake; no real `~/.leo` is touched.
@MainActor struct LeoManagedLaunchLeavesConfigTests {
    typealias Rig = LeoRuntimeManagedStartTests.Rig

    static let config = "/home/test/.leo/leo.yaml"
    /// Has a `web:` section, so the B-339 step has nothing to do either.
    static let yaml = "defaults:\n  model: sonnet\nweb:\n  listen: 127.0.0.1:8370\ntasks: {}\n"

    @Test func postLaunchStepsDoNotWriteViewerPlacement() async throws {
        let rig = Rig()
        try rig.writeOurMarker()
        rig.base.fileSystem.addFile(Self.config, Self.yaml, mode: 0o600)
        rig.base.probe.script(.live(version: "0.57.0"))
        let startup = rig.startup()
        await startup.run()
        rig.log.clear()
        rig.base.fileSystem.clearLog()

        await startup.runPostLaunchSteps()

        #expect(rig.base.fileSystem.contents(of: Self.config) == Self.yaml)
        #expect(rig.base.fileSystem.ops.isEmpty)
        let runs = rig.log.events.compactMap { if case let .run(argv) = $0 { argv } else { nil } }
        #expect(runs.filter { $0.contains("config") }.isEmpty)
    }
}
