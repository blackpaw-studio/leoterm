import Foundation

/// Agents ▸ Jump to Next Needing Attention (⌃⌥⌘J): pure target selection
/// over the *unfiltered* sidebar order.
enum LeoAttentionNavigation {
    /// The next agent needing attention after the focused agent (else the
    /// selected row, else the top), wrapping once and never the focused
    /// agent itself.
    static func next(
        in order: [LeoAgentRow.ID],
        needing: Set<LeoAgentRow.ID>,
        focused: LeoAgentRow.ID?,
        selected: LeoAgentRow.ID?
    ) -> LeoAgentRow.ID? {
        let start = (focused ?? selected).flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let wrapped = order[start...] + order[..<start]
        return wrapped.first { needing.contains($0) && $0 != focused }
    }

    /// Rows whose badge is a needing-attention state (stale states already
    /// have no badge).
    static func needing(_ rows: [LeoAgentRow]) -> Set<LeoAgentRow.ID> {
        Set(rows.filter { $0.attention?.needsAttention == true }.map(\.id))
    }

    /// Whether the sidebar's search `query` hides `row` (so jumping to it
    /// must clear the filter first).
    static func filterHides(_ row: LeoAgentRow, query: String) -> Bool {
        LeoSidebarReducers.filter([row], query: query).isEmpty
    }
}

/// The Dock tile label: the selected host's attention count takes
/// precedence over Ghostty's bell count; zero of both clears it.
enum LeoDockBadge {
    private static let maximumShown = 99

    static func label(attentionCount: Int, bellCount: Int, bellBadgeEnabled: Bool) -> String? {
        let count = attentionCount > 0 ? attentionCount : (bellBadgeEnabled ? bellCount : 0)
        guard count > 0 else { return nil }
        return count > maximumShown ? "\(maximumShown)+" : String(count)
    }
}
