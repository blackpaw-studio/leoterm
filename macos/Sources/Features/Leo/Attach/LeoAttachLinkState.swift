import Foundation

/// What the sidebar needs to know about attach surfaces: which agent row the
/// focused surface shows, and how many live attach tabs/splits each agent
/// has. Keyed by (host, agent), so local and SSH-tunnelled agents with the
/// same name never share an entry.
struct LeoAttachLinkState: Equatable, Sendable {
    let focused: LeoAgentRow.ID?
    let tabCounts: [LeoAgentRow.ID: Int]

    static let empty = LeoAttachLinkState(focused: nil, tabCounts: [:])

    init(focused: LeoAgentRow.ID?, tabCounts: [LeoAgentRow.ID: Int]) {
        self.focused = focused
        self.tabCounts = tabCounts
    }

    /// Only live handles count: an exited attach shows a placeholder, not
    /// the agent.
    init(
        focused: LeoAgentIdentity?,
        handlesByIdentity: [LeoAgentIdentity: [AttachmentHandle]],
        inactive: Set<AttachmentHandle>
    ) {
        self.focused = focused.map(Self.rowID)
        tabCounts = handlesByIdentity.reduce(into: [:]) { counts, entry in
            let live = entry.value.filter { !inactive.contains($0) }.count
            if live > 0 { counts[Self.rowID(entry.key)] = live }
        }
    }

    func tabCount(for id: LeoAgentRow.ID) -> Int { tabCounts[id] ?? 0 }

    private static func rowID(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID {
        LeoAgentRow.ID(host: identity.host, name: identity.name)
    }
}
