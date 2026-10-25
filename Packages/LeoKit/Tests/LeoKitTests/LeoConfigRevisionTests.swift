import Testing

@testable import LeoKit

struct LeoConfigRevisionTests {
    @Test func anUntouchedRevisionResolvesToItself() {
        #expect(LeoConfigRevisionTracker().resolve("sha256:a") == "sha256:a")
    }

    @Test func theAppsOwnWriteMovesEveryPaneHoldingTheOldRevision() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "sha256:a", to: "sha256:b")

        #expect(tracker.resolve("sha256:a") == "sha256:b")
        #expect(tracker.resolve("sha256:b") == "sha256:b")
    }

    @Test func successiveOwnWritesChain() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "b")
        tracker.recordWrite(from: "b", to: "c")

        #expect(tracker.resolve("a") == "c")
        #expect(tracker.resolve("b") == "c")
    }

    @Test func aRevisionThatIsNotTheAppsOwnStaysAsItIs() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "b")

        #expect(tracker.resolve("elsewhere") == "elsewhere")
    }

    @Test func anOutsideChangeAfterOwnWritesStillMismatches() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "b")
        // The file then changed to "c" outside the app: a pane holding "a"
        // resolves to "b", which no longer matches the daemon's "c".
        #expect(tracker.resolve("a") == "b")
        #expect(tracker.resolve("a") != "c")
    }

    @Test func aWriteThatChangedNothingRecordsNothing() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "a")

        #expect(tracker.resolve("a") == "a")
    }

    @Test func aCycleDoesNotLoop() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "b")
        tracker.recordWrite(from: "b", to: "a")

        #expect(["a", "b"].contains(tracker.resolve("a")))
    }

    @Test func resettingForgetsEveryWrite() {
        let tracker = LeoConfigRevisionTracker()
        tracker.recordWrite(from: "a", to: "b")
        tracker.reset()

        #expect(tracker.resolve("a") == "a")
    }
}
