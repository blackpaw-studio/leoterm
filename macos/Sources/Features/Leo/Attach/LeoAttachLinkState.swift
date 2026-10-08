import Foundation

/// What the sidebar needs to know about attach surfaces: which agent row the
/// focused surface shows, and how many live attaches each agent
/// has. Keyed by (host, agent), so local and SSH-tunnelled agents with the
/// same name never share an entry.
struct LeoAttachLinkState: Equatable, Sendable {
    let focused: LeoAgentRow.ID?
    let attachCounts: [LeoAgentRow.ID: Int]
    /// The host focus report (`AttachContentHost.focusReportCount`) `focused`
    /// reflects, so the sidebar can tell a report that was already in
    /// flight when the user selected a row from a newer one.
    let focusReport: Int
    /// The dispatch whose surface has focus, when one does (B-266).
    let focusedDispatch: LeoDispatchRef?

    static let empty = LeoAttachLinkState(focused: nil, attachCounts: [:])

    init(
        focused: LeoAgentRow.ID?, attachCounts: [LeoAgentRow.ID: Int], focusReport: Int = 0,
        focusedDispatch: LeoDispatchRef? = nil
    ) {
        self.focusedDispatch = focusedDispatch
        self.focused = focused
        self.attachCounts = attachCounts
        self.focusReport = focusReport
    }

    /// Only live handles count: an exited attach shows a placeholder, not
    /// the agent.
    init(
        focused: LeoAgentIdentity?,
        handlesByIdentity: [LeoAgentIdentity: [AttachmentHandle]],
        inactive: Set<AttachmentHandle>,
        focusReport: Int
    ) {
        // A dispatch surface maps to its dispatch row, never an agent row.
        self.focused = focused.flatMap { $0.dispatchID == nil ? Self.rowID($0) : nil }
        focusedDispatch = focused.flatMap { identity in identity.dispatchID.map { LeoDispatchRef(host: identity.host, id: $0) } }
        self.focusReport = focusReport
        attachCounts = handlesByIdentity.reduce(into: [:]) { counts, entry in
            guard entry.key.dispatchID == nil else { return }
            let live = entry.value.filter { !inactive.contains($0) }.count
            if live > 0 { counts[Self.rowID(entry.key)] = live }
        }
    }

    func attachCount(for id: LeoAgentRow.ID) -> Int { attachCounts[id] ?? 0 }

    private static func rowID(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID {
        LeoAgentRow.ID(host: identity.host, name: identity.name)
    }
}
