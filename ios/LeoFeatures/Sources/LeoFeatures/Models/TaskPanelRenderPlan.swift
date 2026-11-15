import Foundation

/// Everything the task panel draws from.
public struct TaskPanelRenderKey: Equatable, Sendable {
    public let header: String
    public let rows: [TaskPanelRow]
    public let isCollapsed: Bool
    public let now: Date

    public init(header: String, rows: [TaskPanelRow], isCollapsed: Bool, now: Date) {
        self.header = header
        self.rows = rows
        self.isCollapsed = isCollapsed
        self.now = now
    }
}

/// What the panel does for a new render. Only the clock moving is a relabel:
/// the row views stay rather than being rebuilt.
public enum TaskPanelRenderPlan: Equatable, Sendable {
    case skip, relabel, rebuild

    public init(previous: TaskPanelRenderKey?, next: TaskPanelRenderKey) {
        guard let previous else { self = .rebuild; return }
        if previous.header != next.header || previous.rows != next.rows || previous.isCollapsed != next.isCollapsed {
            self = .rebuild
        } else {
            self = previous.now == next.now ? .skip : .relabel
        }
    }
}
