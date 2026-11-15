import CoreGraphics

/// Where the thread's content sits in its scroll view, in the scroll
/// view's coordinates.
struct LeoChatScrollMetrics: Equatable {
    /// The content's top edge; negative once scrolled down.
    var contentMinY: CGFloat
    var contentHeight: CGFloat
    var viewport: CGSize

    /// How far the content's bottom hangs below the viewport's.
    var distanceFromBottom: CGFloat { contentMinY + contentHeight - viewport.height }
}

/// Keeps the thread on the newest message. A reader at the bottom stays
/// there through resizes, mode switches and new messages; one who scrolled
/// up keeps their place. A change in content height or viewport is layout;
/// anything else that moves the content is the reader scrolling.
struct LeoChatScrollPin: Equatable {
    /// Within this of the bottom counts as at the bottom.
    static let tolerance: CGFloat = 40
    /// Layout jitter below this isn't a content or viewport change.
    private static let epsilon: CGFloat = 0.5

    private(set) var isPinned = true
    private var last: LeoChatScrollMetrics?

    /// The pin after `metrics`, and whether to scroll to the bottom now.
    func measured(_ metrics: LeoChatScrollMetrics) -> (pin: Self, scrollToBottom: Bool) {
        let isAtBottom = metrics.distanceFromBottom <= Self.tolerance
        if let last, !isLayoutChange(from: last, to: metrics) {
            // Only the offset moved: the reader scrolled.
            return (Self(isPinned: isAtBottom, last: metrics), false)
        }
        // A thread's first layout, or its content or viewport changed.
        let pinned = isPinned || isAtBottom
        return (Self(isPinned: pinned, last: metrics), pinned && !isAtBottom)
    }

    /// A different thread: start at its newest message.
    func reset() -> Self { Self() }

    private func isLayoutChange(from old: LeoChatScrollMetrics, to new: LeoChatScrollMetrics) -> Bool {
        abs(new.contentHeight - old.contentHeight) > Self.epsilon
            || abs(new.viewport.width - old.viewport.width) > Self.epsilon
            || abs(new.viewport.height - old.viewport.height) > Self.epsilon
    }
}
