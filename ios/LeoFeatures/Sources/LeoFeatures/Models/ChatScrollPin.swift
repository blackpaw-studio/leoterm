import CoreGraphics

/// A scroll view's geometry, enough to say where its bottom is.
public struct ChatScrollMetrics: Equatable, Sendable {
    public var offsetY: CGFloat
    public var contentHeight: CGFloat
    public var boundsHeight: CGFloat
    public var insetTop: CGFloat
    public var insetBottom: CGFloat

    public init(offsetY: CGFloat, contentHeight: CGFloat, boundsHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.boundsHeight = boundsHeight
        self.insetTop = insetTop
        self.insetBottom = insetBottom
    }

    /// The offset that shows the last point of content above the bottom inset;
    /// the top when the content is shorter than the view.
    public var bottomOffsetY: CGFloat { max(contentHeight - boundsHeight + insetBottom, -insetTop) }

    /// How far the visible area ends above the bottom of the content.
    public var distanceFromBottom: CGFloat { bottomOffsetY - offsetY }
}

/// Whether a chat list follows its newest message. Only the reader's own
/// scrolling changes it, never the list's layout: a keyboard, a growing
/// composer or an image sizing in moves the bottom, and a pinned list moves
/// with it.
public struct ChatScrollPin: Equatable, Sendable {
    /// Within this many points of the bottom counts as at the bottom: rounding
    /// and rubber-banding, not a reader a few lines up (they stay put).
    public static let bottomTolerance: CGFloat = 8
    /// Smaller gaps are rounding, not a layout change to follow.
    private static let tolerance: CGFloat = 0.5

    public private(set) var isPinned = true

    public init() {}

    /// The reader scrolled (a drag or its deceleration): they follow the
    /// bottom only while they rest on it.
    public mutating func userScrolled(_ metrics: ChatScrollMetrics) {
        isPinned = metrics.distanceFromBottom <= Self.bottomTolerance
    }

    /// The reader sent a message: they want to see it, wherever they were.
    public mutating func userSent() { isPinned = true }

    /// The app is about to scroll somewhere else (to reveal a field or a card):
    /// stop following the bottom until the reader scrolls back to it.
    public mutating func release() { isPinned = false }

    /// The offset to move to so a pinned list stays on its bottom; nil when
    /// the list is unpinned or already there.
    public func correction(for metrics: ChatScrollMetrics) -> CGFloat? {
        guard isPinned, abs(metrics.distanceFromBottom) > Self.tolerance else { return nil }
        return metrics.bottomOffsetY
    }
}
