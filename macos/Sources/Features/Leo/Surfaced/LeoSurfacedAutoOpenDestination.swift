import Foundation

/// B-273: which window a file an agent surfaced opens in, chosen without
/// attaching or navigating anything: the window showing the agent, else
/// the one holding its live surface (hidden in a live pool), else one that
/// already has its pane, else the key window (or the preferred parent).
enum LeoSurfacedAutoOpenDestination {
    struct Candidate: Equatable {
        let id: LeoWindowID
        /// The agent's row is the one the window shows.
        let showsAgent: Bool
        /// The agent's live surface is in this window, on screen or pooled.
        let holdsLiveSurface: Bool
        /// The window already has a pane for the agent's row.
        let hasPane: Bool
    }

    /// The first candidate (in order) of the first rule that matches,
    /// else `fallback`.
    static func choose(_ candidates: [Candidate], fallback: LeoWindowID?) -> LeoWindowID? {
        let rules: [(Candidate) -> Bool] = [\.showsAgent, \.holdsLiveSurface, \.hasPane]
        return rules.lazy.compactMap { rule in candidates.first(where: rule)?.id }.first ?? fallback
    }
}

/// B-273: opens a surfaced file in its agent's own pane in the background:
/// a new tab (or the file's own, selected), without focus, without showing
/// the row or navigating the window, and without an error sheet -- a file
/// that can't open just stays pending, for ⌥⌘O to show why. It's seen once
/// the agent's row is on screen in a visible window
/// (`LeoWindowSession.markShownIfVisible`).
@MainActor struct LeoSurfacedAutoOpen {
    /// Every window's session, the key window's first (ties go to it).
    let sessions: @MainActor () -> [LeoWindowSession]
    /// The key window's session, else the preferred parent's.
    let fallback: @MainActor () -> LeoWindowSession?
    /// The window holding an agent's live surface (`LeoAttachCoordinator.liveWindow(of:)`).
    let liveWindow: @MainActor (LeoAgentIdentity) -> LeoWindowID?
    let opener: LeoSurfacedFileOpener

    func open(_ file: LeoSurfacedFile, for row: LeoAgentRow, stillWanted: @escaping @MainActor () -> Bool) async {
        guard stillWanted(), let session = destination(for: row) else { return }
        let tabs = session.panes.pane(for: .agent(row.identity)).tabs
        // Its place in line is taken now, before the stat: a file surfaced
        // later, or a tab the user picks meanwhile, keeps the selection.
        let request = tabs.request(.background)
        let target = LeoSurfacedFileOpener.Target(
            stat: { try await tabs.stat($0) },
            open: { fileID, line, isStillWanted in
                try await tabs.open(fileID, line: line, request: request, readDeadline: .surfacedOpen, isStillWanted: isStillWanted)
            },
            reportError: { _ in },
            isStillWanted: stillWanted,
            whenSeen: { [weak session, weak tabs] mark in
                tabs?.whenShown(mark)
                session?.markShownIfVisible()
            }
        )
        await opener.open(file, host: row.host, in: target)
    }

    private func destination(for row: LeoAgentRow) -> LeoWindowSession? {
        let key = LeoRowKey.agent(row.identity)
        let sessions = sessions()
        let live = liveWindow(row.identity)
        let candidates = sessions.map { session in
            LeoSurfacedAutoOpenDestination.Candidate(
                id: session.id, showsAgent: session.panes.activeKey == key, holdsLiveSurface: session.id == live,
                hasPane: session.panes.existingPane(for: key) != nil
            )
        }
        let fallback = fallback()
        guard let id = LeoSurfacedAutoOpenDestination.choose(candidates, fallback: fallback?.id) else { return nil }
        return sessions.first { $0.id == id } ?? fallback
    }
}
