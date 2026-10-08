import Testing

@testable import Ghostty

struct LeoDaemonFeaturesScopeTests {
    private let placement = LeoDaemonFeatures(["attach_dispatch_placement"])

    @Test func featuresApplyToTheHostTheyWereAdvertisedBy() {
        #expect(placement.applying(to: .remote("A"), advertisedBy: .remote("A")) == placement)
        #expect(placement.applying(to: .local, advertisedBy: .local) == placement)
    }

    @Test func featuresDoNotApplyToAnotherHost() {
        #expect(placement.applying(to: .remote("B"), advertisedBy: .remote("A")) == .none)
        #expect(placement.applying(to: .local, advertisedBy: .remote("A")) == .none)
    }

    @Test func featuresDoNotApplyWhenNoHostIsKnown() {
        #expect(placement.applying(to: .local, advertisedBy: nil) == .none)
    }
}
