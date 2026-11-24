import CoreGraphics

/// A pane the user docks (B-439): the agent's web view, or the row's files
/// (the workspace outline with the editor and plugin tabs, as one unit).
enum LeoDockPane: String, CaseIterable, Sendable {
    case browser
    case files

    /// What menus call it.
    var title: String {
        switch self {
        case .browser: "Browser"
        case .files: "Files"
        }
    }
}

/// Where a pane docks: beside the terminal, or under it (above the agent
/// drawer).
enum LeoDockEdge: String, CaseIterable, Sendable {
    case right
    case below
}

/// The open panes docked on one edge, in tab order.
struct LeoDockGroup: Equatable, Sendable {
    let edge: LeoDockEdge
    let panes: [LeoDockPane]

    /// Files keeps its outline as a leading column wherever it docks.
    var hasOutline: Bool { panes.contains(.files) }
}

/// Each pane's edge, the same for every agent and every window.
struct LeoPaneDockLayout: Equatable, Sendable {
    private var browser = LeoDockEdge.right
    private var files = LeoDockEdge.right

    /// Everything on the right: the layout before docking existed.
    init() {}

    func edge(of pane: LeoDockPane) -> LeoDockEdge {
        switch pane {
        case .browser: browser
        case .files: files
        }
    }

    func moving(_ pane: LeoDockPane, to edge: LeoDockEdge) -> Self {
        var next = self
        switch pane {
        case .browser: next.browser = edge
        case .files: next.files = edge
        }
        return next
    }

    /// Whether the two panes share an edge, and so one tab group.
    var isShared: Bool { edge(of: .browser) == edge(of: .files) }

    /// The panes docked on `edge`, in tab order: the Browser item leads,
    /// as it does in the strip.
    func panes(on edge: LeoDockEdge) -> [LeoDockPane] {
        LeoDockPane.allCases.filter { self.edge(of: $0) == edge }
    }

    /// The groups the `open` panes form: one per edge with an open pane,
    /// the right edge first.
    func groups(open: Set<LeoDockPane>) -> [LeoDockGroup] {
        LeoDockEdge.allCases.compactMap { edge in
            let panes = panes(on: edge).filter(open.contains)
            return panes.isEmpty ? nil : LeoDockGroup(edge: edge, panes: panes)
        }
    }
}

enum LeoPaneDockMetrics {
    /// A dock's divider stops here; it never drags closed.
    static let minimumSize: CGFloat = 200
    /// What a dock opening at its remembered size leaves the terminal, when
    /// there's room; the dock's own minimum wins when there isn't.
    static let terminalFloor: CGFloat = 120

    /// A dock `size` big where `available` is the terminal's and the dock's
    /// together: at least `minimumSize`, and otherwise leaving the terminal
    /// `terminalFloor` (the right dock keeps the wider floor the side panes
    /// always have, `LeoSidebarSplitMetrics.terminalFloor`).
    static func clampedSize(_ size: CGFloat, available: CGFloat, terminalFloor: CGFloat = terminalFloor) -> CGFloat {
        max(minimumSize, min(size, available - terminalFloor))
    }
}
