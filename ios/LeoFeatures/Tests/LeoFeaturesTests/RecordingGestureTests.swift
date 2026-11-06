import CoreGraphics
import Testing

@testable import LeoFeatures

struct RecordingGestureTests {
    let start = CGPoint(x: 300, y: 600)

    @Test func verticalDriftNeverCancels() {
        #expect(!RecordingGesture.shouldCancel(start: start, current: CGPoint(x: 300, y: 100)))
        #expect(!RecordingGesture.shouldCancel(start: start, current: CGPoint(x: 300, y: 900)))
    }

    @Test func smallLeftDriftDoesNotCancel() {
        #expect(!RecordingGesture.shouldCancel(start: start, current: CGPoint(x: 300 - 119, y: 600)))
    }

    @Test func leftPastTheThresholdCancels() {
        let edge = CGPoint(x: start.x - RecordingGesture.cancelDistance, y: 600)
        #expect(RecordingGesture.shouldCancel(start: start, current: edge))
        #expect(RecordingGesture.shouldCancel(start: start, current: CGPoint(x: 100, y: 580)))
    }

    @Test func rightwardDriftNeverCancels() {
        #expect(!RecordingGesture.shouldCancel(start: start, current: CGPoint(x: 700, y: 600)))
    }
}
