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
}
