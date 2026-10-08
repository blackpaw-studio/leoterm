import Foundation
import Testing

@testable import Ghostty

/// A daemon's features apply only to the host that advertised them, judged by
/// the stamp the feed put on them -- never by the live host selection, which
/// moves before the feed's reset lands.
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

    /// The race: the user selects host B while the model still holds A's
    /// snapshot. An attach to B in that gap must not get A's placement flag.
    @MainActor @Test func attachToANewlySelectedHostGetsNoFlagWhileTheModelStillHoldsTheOldHostsFeatures() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: ["attach_dispatch_placement"]))
        try await harness.pump { $0.features.contains(.attachDispatchPlacement) }
        let model = LeoSidebarModel(snapshot: try #require(await harness.recorder.last))

        #expect(model.hostFeatures.applying(to: .remote("B")).attachPlacementArguments.isEmpty)
        #expect(model.hostFeatures.applying(to: .local).attachPlacementArguments == ["--dispatch-placement", "background"])
        await harness.stop()
    }

    /// The same race through the closures `LeoRuntime` injects: the model
    /// holds A's stamped features, the selection has moved to B, and B's
    /// hello has not arrived. B's attach command must carry no flag; A's
    /// still does, since the stamp names A.
    @MainActor @Test func runtimeAttachCommandsScopeFeaturesByTheStampNotTheSelection() async throws {
        let hosts = ["A", "B"].map { LeoHostConfiguration(name: $0, sshTarget: "evan@\($0)", remoteSocketPath: "/remote/leo.sock") }
        let defaults = LeoInMemoryDefaults()
        defaults.set(try JSONEncoder().encode(hosts), forKey: LeoHostStore.key)
        let runtime = LeoRuntime(
            daemon: EmptyDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(),
            hostConnectionTransport: LeoAlwaysHealthyTransport(),
            hostSelectionSSHExecutable: LeoTunnelTestSupport.fixtureURL(),
            hostSelectionLegacySocketDirectory: LeoHostSelectionTestSupport.localSocketDirectory,
            hostSelectionControlSocketDirectory: LeoHostSelectionTestSupport.localSocketDirectory
        )
        defer { runtime.shutdown() }
        await runtime.hostSelection.start(flavor: .socketEvents)
        runtime.hostSelection.select(.remote("B"))
        runtime.model.receive(LeoSidebarSnapshot(
            rows: [], connectivity: .connected, generation: .max, features: Self.placement, featuresHost: .remote("A")
        ))
        let flag = "--dispatch-placement"

        let onB = try runtime.attachCoordinator.attachCommand(for: .init(host: .remote("B"), name: "bob")).get()
        let onA = try runtime.attachCoordinator.attachCommand(for: .init(host: .remote("A"), name: "amy")).get()

        #expect(runtime.hostSelection.selected == .remote("B"))
        #expect(!onB.contains(flag), "B's hello hasn't arrived: \(onB)")
        #expect(onA.contains("\(flag) background"), "A's stamped features still apply to A: \(onA)")
    }
}
