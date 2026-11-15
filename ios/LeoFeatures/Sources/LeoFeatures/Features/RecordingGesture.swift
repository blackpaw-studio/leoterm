import CoreGraphics

/// Decides when a hold-to-record drag becomes a cancel.
public enum RecordingGesture {
    /// How far left of the press-start point a drag must travel to cancel.
    public static let cancelDistance: CGFloat = 120

    /// A deliberate slide left cancels; vertical and rightward drift never do.
    public static func shouldCancel(start: CGPoint, current: CGPoint) -> Bool {
        start.x - current.x >= cancelDistance
    }
}
