/// What the toolbar's Terminal | Chat switch shows for the shown agent, and
/// how a click on it maps back to a view choice. Pure: the AppKit control
/// only mirrors it.
///
/// `layout` is nil while no agent is shown (a shell row, or nothing
/// selected): the switch stays in the toolbar, disabled and unlit.
struct LeoViewSwitchPresentation: Equatable {
    /// Segment order: left to right.
    static let choices: [LeoAgentViewChoice] = [.terminal, .chat]
    static let tooltips = ["Terminal", "Chat"]
    static let groupLabel = "View"

    let isEnabled: Bool
    /// The lit segments: both while Chat sits beside the terminal.
    let selected: Set<LeoAgentViewChoice>
    /// Unread chat messages, as a dot on the Chat segment. Chat on screen is
    /// being read, so it has none then.
    let showsUnreadDot: Bool
    let chatAccessibilityLabel: String

    init(layout: LeoChatLayout?, unreadCount: Int) {
        isEnabled = layout != nil
        selected = layout?.activeSegments ?? []
        let unread = layout.map { $0.showsChat ? 0 : max(0, unreadCount) } ?? 0
        showsUnreadDot = unread > 0
        chatAccessibilityLabel = unread > 0 ? "Chat, \(unread) unread" : "Chat"
    }

    /// With `.selectAny` a click flips its segment, so the clicked one is the
    /// segment whose state no longer matches what is shown. Nil when nothing differs.
    func clicked(segmentStates: [Bool]) -> LeoAgentViewChoice? {
        Self.choices.indices.first { index in
            segmentStates.indices.contains(index) && segmentStates[index] != selected.contains(Self.choices[index])
        }.map { Self.choices[$0] }
    }
}
