/// The agent detail screen's sections, in display order.
public enum AgentDetailSection: Int, CaseIterable, Hashable, Sendable {
    case header, claude, brief, tasks, live, status, environment, move, actions

    /// Whether the section is drawn under a title. The identity block and the
    /// Open in Claude card stand alone; the live rows (Chat, Terminal, Browser)
    /// have no title either.
    public var hasHeader: Bool {
        switch self {
        case .header, .claude, .live: false
        case .brief, .tasks, .status, .environment, .move, .actions: true
        }
    }
}

/// Which sections the screen shows. A section with no rows is absent, so the
/// section at a position is never the section that would sit there if every
/// one were shown: a screen that titles by position must ask the plan, not the
/// enum's raw value.
public struct AgentDetailSectionPlan: Equatable, Sendable {
    public let sections: [AgentDetailSection]

    public init(itemCounts: [AgentDetailSection: Int]) {
        sections = AgentDetailSection.allCases.filter { (itemCounts[$0] ?? 0) > 0 }
    }

    /// The section at a position among the visible ones.
    public func section(at index: Int) -> AgentDetailSection? {
        sections.indices.contains(index) ? sections[index] : nil
    }

    /// The visible sections that carry a title.
    public var headedSections: [AgentDetailSection] { sections.filter(\.hasHeader) }
}
