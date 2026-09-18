import Foundation

/// Pure decision for `TerminalController.leoApplyInitialSize(attempt:)`: is
/// a just-measured `window.contentView.intrinsicContentSize` plausible
/// enough to apply as the window's content size, or does it still reflect
/// the empty placeholder view from before SwiftUI re-rendered with the
/// newly-attached `SurfaceView`?
///
/// No AppKit dependency -- takes plain sizes so it's directly testable.
enum LeoInitialSizeDecision {
    /// How many `DispatchQueue.main.async` turns `leoApplyInitialSize`
    /// retries before giving up and leaving the window at its current size.
    static let maxAttempts = 10

    /// The floor used only when `cellSize` is zero/unknown (before the
    /// surface has ever reported one) -- twice an unknown cell size is
    /// still zero, so this is the sole guard against a near-zero intrinsic
    /// size in that case. Deliberately small: once a real cell size is
    /// known, `2 * cellSize` alone is the plausibility bar, however small
    /// a configured window (e.g. 40 columns at a 2-pt cell) may be.
    private static let unknownCellSizeFloorPoints: CGFloat = 16

    /// `intrinsic` is plausible when both dimensions are at least twice the
    /// surface's cell size -- comfortably bigger than a single-cell
    /// placeholder view. Falls back to `unknownCellSizeFloorPoints` only
    /// for a dimension whose cell size is still zero.
    static func shouldApply(intrinsic: CGSize, cellSize: CGSize) -> Bool {
        let minWidth = cellSize.width > 0 ? cellSize.width * 2 : unknownCellSizeFloorPoints
        let minHeight = cellSize.height > 0 ? cellSize.height * 2 : unknownCellSizeFloorPoints
        return intrinsic.width >= minWidth && intrinsic.height >= minHeight
    }

    /// Whether `leoApplyInitialSize`'s deferred retry loop should continue
    /// for another turn. Stops (without applying anything) the moment the
    /// window is no longer visible/has closed, or the moment its frame has
    /// changed since the retry was scheduled -- either means the user (or
    /// something else) has already taken over sizing/positioning this
    /// window, and a delayed intrinsic-size apply must never clobber that.
    static func shouldContinue(attempt: Int, frameAtSchedule: CGRect, currentFrame: CGRect, isVisible: Bool) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard isVisible else { return false }
        guard frameAtSchedule == currentFrame else { return false }
        return true
    }
}
