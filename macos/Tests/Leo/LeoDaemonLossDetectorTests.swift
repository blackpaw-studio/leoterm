import Testing

@testable import Ghostty
@testable import LeoKit

/// `LeoDaemonLossDetector` reads a machine's feed for a daemon that dropped
/// behind a connection still up, and one that answered again.
struct LeoDaemonLossDetectorTests {
    private let lost = LeoConnectivity.disconnected(reason: "event stream ended", isRetrying: false)
    private let retrying = LeoConnectivity.disconnected(reason: "event stream ended", isRetrying: true)

    @Test func aLiveFeedThatDropsReportsTheLossOnce() {
        var detector = LeoDaemonLossDetector()
        #expect(detector.observe(.loading, for: .local) == nil)
        #expect(detector.observe(.connected, for: .local) == .answered)

        #expect(detector.observe(lost, for: .local) == .stoppedAnswering(reason: "event stream ended"))
        #expect(detector.observe(lost, for: .local) == nil, "a dropped feed re-emitting is not a new loss")
    }

    @Test func aRetryThatFailsIsANewLossAndOneThatLandsHasAnswered() {
        var detector = LeoDaemonLossDetector()
        _ = detector.observe(.connected, for: .local)
        _ = detector.observe(lost, for: .local)

        #expect(detector.observe(retrying, for: .local) == nil)
        #expect(detector.observe(lost, for: .local) == .stoppedAnswering(reason: "event stream ended"))
        #expect(detector.observe(retrying, for: .local) == nil)
        #expect(detector.observe(.connected, for: .local) == .answered)
        #expect(detector.observe(.connected, for: .local) == nil)
    }

    @Test func aFeedThatNeverWentLiveOrFailedReportsNothing() {
        var detector = LeoDaemonLossDetector()
        #expect(detector.observe(.loading, for: .remote("b")) == nil)
        #expect(detector.observe(.failed(message: "refused"), for: .remote("b")) == nil)
    }

    @Test func eachMachineIsReadOnItsOwn() {
        var detector = LeoDaemonLossDetector()
        _ = detector.observe(.connected, for: .local)
        _ = detector.observe(lost, for: .local)

        #expect(detector.observe(.connected, for: .remote("b")) == .answered)
        #expect(detector.observe(lost, for: .remote("b")) == .stoppedAnswering(reason: "event stream ended"))
    }
}
