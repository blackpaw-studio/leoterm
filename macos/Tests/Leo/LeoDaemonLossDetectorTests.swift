import Testing

@testable import Ghostty
@testable import LeoKit

/// `LeoDaemonLossDetector` reads a machine's feed for a daemon that dropped
/// behind a connection still up, and one that answered again. Every drop
/// mints a new snapshot generation; a re-emit keeps its own.
struct LeoDaemonLossDetectorTests {
    @Test func aLiveFeedThatDropsReportsTheLossOnce() {
        var detector = LeoDaemonLossDetector()
        #expect(detector.observe(snapshot(.loading, 1), for: .local) == nil)
        #expect(detector.observe(snapshot(.connected, 2), for: .local) == .answered)

        #expect(detector.observe(lost(3), for: .local) == .stoppedAnswering(reason: "event stream ended"))
        #expect(detector.observe(lost(3), for: .local) == nil, "a dropped feed re-emitting is not a new loss")
    }

    @Test func aRetryThatFailsIsANewLossAndOneThatLandsHasAnswered() {
        var detector = LeoDaemonLossDetector()
        _ = detector.observe(snapshot(.connected, 1), for: .local)
        _ = detector.observe(lost(2), for: .local)

        #expect(detector.observe(retrying(3), for: .local) == nil)
        #expect(detector.observe(lost(4), for: .local) == .stoppedAnswering(reason: "event stream ended"))
        #expect(detector.observe(retrying(5), for: .local) == nil)
        #expect(detector.observe(snapshot(.connected, 6), for: .local) == .answered)
        #expect(detector.observe(snapshot(.connected, 6), for: .local) == nil)
    }

    /// This Mac's Retry connects at once, so its feed can drop again without
    /// ever showing that it was retrying.
    @Test func aRetryThatDropsWithoutShowingItWasRetryingIsStillANewLoss() {
        var detector = LeoDaemonLossDetector()
        _ = detector.observe(snapshot(.connected, 1), for: .local)
        _ = detector.observe(lost(2), for: .local)

        #expect(detector.observe(lost(4), for: .local) == .stoppedAnswering(reason: "event stream ended"))
    }

    @Test func aFeedThatNeverWentLiveOrFailedReportsNothing() {
        var detector = LeoDaemonLossDetector()
        #expect(detector.observe(snapshot(.loading, 1), for: .remote("b")) == nil)
        #expect(detector.observe(snapshot(.failed(message: "refused"), 2), for: .remote("b")) == nil)
    }

    @Test func eachMachineIsReadOnItsOwn() {
        var detector = LeoDaemonLossDetector()
        _ = detector.observe(snapshot(.connected, 1), for: .local)
        _ = detector.observe(lost(2), for: .local)

        #expect(detector.observe(snapshot(.connected, 2), for: .remote("b")) == .answered)
        #expect(detector.observe(lost(3), for: .remote("b")) == .stoppedAnswering(reason: "event stream ended"))
    }

    private func snapshot(_ connectivity: LeoConnectivity, _ generation: Int) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(rows: [], connectivity: connectivity, generation: generation)
    }

    private func lost(_ generation: Int) -> LeoSidebarSnapshot {
        snapshot(.disconnected(reason: "event stream ended", isRetrying: false), generation)
    }

    private func retrying(_ generation: Int) -> LeoSidebarSnapshot {
        snapshot(.disconnected(reason: "event stream ended", isRetrying: true), generation)
    }
}
