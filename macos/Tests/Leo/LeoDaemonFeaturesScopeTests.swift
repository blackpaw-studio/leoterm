import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A daemon's features apply only to the machine that advertised them:
/// judged by the stamp the feed put on them, and kept in that machine's own
/// snapshot.
@Suite(.timeLimit(.minutes(1)))
struct LeoDaemonFeaturesScopeTests {
    private static let placement = LeoDaemonFeatures(["attach_dispatch_placement"])

    @Test func featuresApplyToTheHostTheyWereAdvertisedBy() {
        let local = LeoHostFeatures(host: .local, features: Self.placement)
        let remote = LeoHostFeatures(host: .remote("A"), features: Self.placement)
        #expect(local.applying(to: .local) == Self.placement)
        #expect(remote.applying(to: .remote("A")) == Self.placement)
    }

    @Test func featuresDoNotApplyToAnotherHost() {
        let remote = LeoHostFeatures(host: .remote("A"), features: Self.placement)
        #expect(remote.applying(to: .remote("B")) == .none)
        #expect(remote.applying(to: .local) == .none)
    }

    @Test func unstampedFeaturesApplyToNoHost() {
        #expect(LeoHostFeatures.none.applying(to: .local) == .none)
    }

    /// B has no snapshot yet while the model holds This Mac's: an attach to
    /// B in that gap must not get This Mac's placement flag.
    @MainActor @Test func attachToAMachineWithoutASnapshotGetsNoFlagWhileAnotherMachineAdvertisesIt() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: ["attach_dispatch_placement"]))
        try await harness.pump { $0.features.contains(.attachDispatchPlacement) }
        let model = LeoSidebarModel(snapshot: try #require(await harness.recorder.last))

        #expect(model.features(for: .remote("B")).attachPlacementArguments.isEmpty)
        #expect(model.features(for: .local).attachPlacementArguments == ["--dispatch-placement", "background"])
        await harness.stop()
    }

    /// The same gap through the closures `LeoRuntime` injects: the model
    /// holds A's stamped features and B's hello has not arrived. B's attach
    /// command must carry no flag; A's still does.
    @MainActor @Test func runtimeAttachCommandsScopeFeaturesToTheMachineThatAdvertisedThem() async throws {
        let hosts = ["A", "B"].map { LeoHostConfiguration(name: $0, sshTarget: "evan@\($0)", remoteSocketPath: "/remote/leo.sock") }
        let defaults = LeoInMemoryDefaults()
        defaults.set(try JSONEncoder().encode(hosts), forKey: LeoHostStore.key)
        let runtime = LeoRuntime(
            daemon: EmptyDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(),
            machineLegacySocketDirectory: LeoMachineTunnelTestSupport.localSocketDirectory,
            machineControlSocketDirectory: LeoMachineTunnelTestSupport.localSocketDirectory,
            makeTunnel: LeoFakeTunnels().factory,
            feedsRemoteMachines: true
        )
        defer { runtime.shutdown() }
        runtime.model.receive(LeoSidebarSnapshot(
            rows: [], connectivity: .connected, generation: .max, features: Self.placement, featuresHost: .remote("A")
        ), for: .remote("A"))
        let flag = "--dispatch-placement"

        let onB = try runtime.attachCoordinator.attachCommand(for: .init(host: .remote("B"), name: "bob")).get()
        let onA = try runtime.attachCoordinator.attachCommand(for: .init(host: .remote("A"), name: "amy")).get()

        #expect(!onB.contains(flag), "B's hello hasn't arrived: \(onB)")
        #expect(onA.contains("\(flag) background"), "A's stamped features still apply to A: \(onA)")
    }
}
