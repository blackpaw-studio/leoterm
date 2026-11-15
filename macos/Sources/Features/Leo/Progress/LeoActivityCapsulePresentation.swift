import CoreGraphics
import Foundation
import LeoKit

/// The toolbar's activity capsule: what it shows for the selected agent's
/// tasks, how it degrades at narrow widths, and what its popover lists. Pure;
/// the view only draws it.
struct LeoActivityCapsulePresentation: Equatable {
    enum TextRole: Equatable { case title, status }

    enum Glyph: Equatable {
        case spinner, succeeded, failed, cancelled
        /// A static dot tinted by the agent's state (nil: no agent, muted).
        case dot(AgentState?)
    }

    /// What the capsule says when the agent has no task.
    enum AgentState: Equatable {
        case working, idle, needsYou, errored

        /// Needs-you and an error outrank working, as in the sidebar row.
        init(attention: LeoAttentionBadge?, isWorking: Bool) {
            switch attention {
            case .needsInput: self = .needsYou
            case .errored: self = .errored
            case .working: self = .working
            case .finished, nil: self = isWorking ? .working : .idle
            }
        }

        var text: String {
            switch self {
            case .working: "Working"
            case .idle: "Idle"
            case .needsYou: "Needs you"
            case .errored: "Errored"
            }
        }
    }

    enum Kind: Equatable { case tasks, agentState, noAgent }

    enum Variant: Equatable {
        /// Title and status text.
        case full
        /// Status text dropped; the title truncates to what is left.
        case titleOnly
    }

    struct Badge: Equatable {
        let count: Int
        let isRed: Bool
    }

    struct Row: Equatable, Identifiable {
        enum Tile: Equatable { case running, succeeded, failed, cancelled }

        let id: String
        let tile: Tile
        let title: String
        let bar: LeoAgentRowPresentation.Progress.Kind
        let statusLine: String
        let canDismiss: Bool
    }

    struct Popover: Equatable {
        /// "3 · 1 failed"; the failed part is omitted at zero.
        let summary: String
        let rows: [Row]
        /// Shown in place of the rows when there are none.
        let emptyMessage: String?
    }

    static let maxWidth: CGFloat = 500
    /// Spinner/glyph, gaps and padding around the text.
    private static let baseChrome: CGFloat = 52
    private static let badgeChrome: CGFloat = 28
    private static let textGap: CGFloat = 8

    /// Width of everything that is not text; the capsule never shrinks below it.
    static func chromeWidth(badge: Bool) -> CGFloat { baseChrome + (badge ? badgeChrome : 0) }

    /// Always true: the capsule never leaves an agent window (spec amendment 2026-11-04).
    let isVisible: Bool
    let kind: Kind
    /// False for "No agent": nothing to open.
    let isEnabled: Bool
    let glyph: Glyph
    let title: String?
    let statusText: String?
    let bar: LeoAgentRowPresentation.Progress.Kind?
    let badge: Badge?
    let variant: Variant
    /// The capsule's width: capped at `maxWidth` and the space offered.
    let width: CGFloat
    let accessibilityLabel: String
    let popover: Popover

    init(
        tasks: LeoRowTasks, state: AgentState = .idle, now: Date, availableWidth: CGFloat, measure: (String, TextRole) -> CGFloat
    ) {
        let ordered = LeoAgentTasks.ordered(tasks.tasks)
        guard let primary = ordered.first else {
            self = Self(
                kind: .agentState, isEnabled: true, glyph: .dot(state), title: state.text,
                width: min(availableWidth, Self.maxWidth), accessibilityLabel: "\(state.text), no tasks")
            return
        }
        let status = LeoTaskDetailText.status(primary, now: now) ?? LeoTaskDetailText.trailing(primary, etaAt: tasks.eta(for: primary), now: now)
        let badge = ordered.count >= 2 ? Badge(count: ordered.count, isRed: ordered.contains { $0.state == .failed }) : nil
        let width = min(availableWidth, Self.maxWidth)
        let needed = Self.chromeWidth(badge: badge != nil) + measure(primary.title, .title) + Self.textGap + measure(status, .status)

        isVisible = true
        kind = .tasks
        isEnabled = true
        glyph = Glyph(primary.state)
        title = primary.title
        statusText = status
        bar = .init(primary)
        self.badge = badge
        variant = needed <= width ? .full : .titleOnly
        self.width = width
        accessibilityLabel = "\(primary.title), \(status), \(ordered.count) \(ordered.count == 1 ? "task" : "tasks")"
        popover = Popover(
            summary: Self.summary(ordered),
            rows: ordered.map { Row($0, etaAt: tasks.eta(for: $0), now: now) },
            emptyMessage: nil
        )
    }

    /// A capsule with no task to show: the agent's state, or "No agent".
    private init(kind: Kind, isEnabled: Bool, glyph: Glyph, title: String, width: CGFloat, accessibilityLabel: String) {
        isVisible = true
        self.kind = kind
        self.isEnabled = isEnabled
        self.glyph = glyph
        self.title = title
        statusText = nil
        bar = nil
        badge = nil
        variant = .full
        self.width = width
        self.accessibilityLabel = accessibilityLabel
        popover = Popover(summary: "", rows: [], emptyMessage: isEnabled ? "No tasks" : nil)
    }

    /// A terminal row or the start screen: nothing to open.
    static func noAgent(availableWidth: CGFloat) -> Self {
        Self(
            kind: .noAgent, isEnabled: false, glyph: .dot(nil), title: "No agent", width: min(availableWidth, maxWidth),
            accessibilityLabel: "No agent")
    }

    private static func summary(_ tasks: [LeoAgentTask]) -> String {
        let failed = tasks.filter { $0.state == .failed }.count
        return failed > 0 ? "\(tasks.count) · \(failed) failed" : "\(tasks.count)"
    }
}

extension LeoActivityCapsulePresentation.Glyph {
    fileprivate init(_ state: LeoAgentTask.State) {
        switch state {
        case .running: self = .spinner
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

extension LeoActivityCapsulePresentation.Row {
    fileprivate init(_ task: LeoAgentTask, etaAt: Date?, now: Date) {
        id = task.id
        tile =
            switch task.state {
            case .running: .running
            case .succeeded: .succeeded
            case .failed: .failed
            case .cancelled: .cancelled
            }
        title = task.title
        bar = .init(task)
        statusLine = LeoTaskDetailText.status(task, now: now) ?? LeoTaskDetailText.timing(task, etaAt: etaAt, now: now)
        canDismiss = LeoTaskDetailText.canDismiss(task)
    }
}
