import Foundation
import Testing

@testable import Ghostty

struct LeoInitialSizeDecisionTests {
    private let cellSize = CGSize(width: 10, height: 20)

    @Test func rejectsNearZeroIntrinsicSizeFromAnUnrenderedPlaceholder() {
        #expect(!LeoInitialSizeDecision.shouldApply(intrinsic: .zero, cellSize: cellSize))
        #expect(!LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 10, height: 20), cellSize: cellSize))
    }

    @Test func rejectsWhenOnlyOneDimensionIsPlausible() {
        #expect(!LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 800, height: 20), cellSize: cellSize))
        #expect(!LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 10, height: 600), cellSize: cellSize))
    }

    @Test func acceptsASizeAtLeastTwiceTheCellSize() {
        #expect(LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 20, height: 40), cellSize: cellSize))
        #expect(LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 400, height: 300), cellSize: cellSize))
    }

    /// A real configured window (e.g. `window-width = 238`, `window-height
    /// = 56` measured out in points via a realistic cell size) must not be
    /// mistaken for the collapsed placeholder case.
    @Test func acceptsARealisticConfiguredWindowSize() {
        let realisticCellSize = CGSize(width: 9, height: 18)
        let intrinsic = CGSize(width: 238 * 9, height: 56 * 18)
        #expect(LeoInitialSizeDecision.shouldApply(intrinsic: intrinsic, cellSize: realisticCellSize))
    }

    /// A genuinely tiny but real configured window (40 columns at an
    /// unusually small 2-pt cell) must be accepted -- the plausibility bar
    /// is purely `2 * cellSize`, with no fixed floor once cell size is
    /// known, however small the result.
    @Test func acceptsATinyButRealConfiguredWindowWithASmallCellSize() {
        let tinyCellSize = CGSize(width: 2, height: 2)
        let intrinsic = CGSize(width: 40 * 2, height: 20 * 2)
        #expect(LeoInitialSizeDecision.shouldApply(intrinsic: intrinsic, cellSize: tinyCellSize))
    }

    /// A degenerate (zero) cell size falls back to a small absolute floor
    /// (the surface hasn't reported a real cell size yet, so `2 * cellSize`
    /// can't be used to distinguish a real size from the placeholder).
    @Test func fallsBackToASmallAbsoluteFloorWithAZeroCellSize() {
        #expect(!LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 10, height: 10), cellSize: .zero))
        #expect(LeoInitialSizeDecision.shouldApply(intrinsic: CGSize(width: 20, height: 20), cellSize: .zero))
    }

    @Test func shouldContinueStopsWhenAttemptReachesTheMax() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(!LeoInitialSizeDecision.shouldContinue(
            attempt: LeoInitialSizeDecision.maxAttempts,
            frameAtSchedule: frame, currentFrame: frame, isVisible: true
        ))
        #expect(LeoInitialSizeDecision.shouldContinue(
            attempt: LeoInitialSizeDecision.maxAttempts - 1,
            frameAtSchedule: frame, currentFrame: frame, isVisible: true
        ))
    }

    @Test func shouldContinueStopsWhenTheWindowIsNoLongerVisible() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(!LeoInitialSizeDecision.shouldContinue(attempt: 0, frameAtSchedule: frame, currentFrame: frame, isVisible: false))
    }

    /// A user resize/move between when a retry was scheduled and when it
    /// runs means someone already took over sizing this window -- the
    /// deferred apply must never clobber that.
    @Test func shouldContinueStopsWhenTheFrameChangedSinceScheduling() {
        let scheduled = CGRect(x: 0, y: 0, width: 400, height: 300)
        let moved = CGRect(x: 50, y: 0, width: 400, height: 300)
        #expect(!LeoInitialSizeDecision.shouldContinue(attempt: 0, frameAtSchedule: scheduled, currentFrame: moved, isVisible: true))
    }
}
