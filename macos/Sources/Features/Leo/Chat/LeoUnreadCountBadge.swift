import LeoKit
import SwiftUI

/// A count capsule for unread chat messages: nothing at 0, `99+` over 99.
/// On a selected row (an accent highlight) the colors invert, so it stays
/// visible against the selection.
struct LeoUnreadCountBadge: View {
    let count: Int
    var isOnSelection = false

    var body: some View {
        if let text = LeoChatUnreadCounts.badgeText(count) {
            Text(text)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOnSelection ? Color.accentColor : Color.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(isOnSelection ? Color.white : Color.accentColor))
                .fixedSize()
                .accessibilityLabel("\(count) unread")
        }
    }
}

extension View {
    /// The unread capsule on the top trailing corner of the Terminal | Chat
    /// switch, where its Chat segment ends. NSSegmentedControl can't badge,
    /// so this is an overlay that leaves clicks to the control.
    func chatSegmentBadge(unreadCount: Int) -> some View {
        overlay(alignment: .topTrailing) {
            LeoUnreadCountBadge(count: unreadCount)
                .offset(x: 6, y: -6)
                .allowsHitTesting(false)
        }
    }
}
