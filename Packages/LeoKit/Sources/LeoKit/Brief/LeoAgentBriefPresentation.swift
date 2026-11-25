import Foundation

/// A brief ready to show: text trimmed, empty bullets dropped, age and
/// staleness resolved against injected times.
public struct LeoAgentBriefPresentation: Equatable, Sendable {
    /// A brief this far older than the agent's last activity is stale.
    public static let staleInterval: TimeInterval = 24 * 60 * 60

    public let goal: String?
    public let status: String?
    public let decisions: [String]
    public let open: [String]
    /// "12m ago"; nil when the brief has no update time.
    public let ageText: String?
    /// Show the age in secondary color.
    public let isStale: Bool

    /// Nil when there is nothing to show, so the section stays hidden.
    public init?(brief: LeoAgentBrief?, lastActivity: Date?, now: Date) {
        guard let brief else { return nil }
        let goal = Self.clean(brief.goal)
        let status = Self.clean(brief.status)
        let decisions = brief.decisions.compactMap(Self.clean)
        let open = brief.open.compactMap(Self.clean)
        guard goal != nil || status != nil || !decisions.isEmpty || !open.isEmpty else { return nil }
        self.goal = goal
        self.status = status
        self.decisions = decisions
        self.open = open
        ageText = brief.updatedAt.map { Self.age(from: $0, to: now) }
        isStale = switch (brief.updatedAt, lastActivity) {
        case (let updated?, let activity?): activity.timeIntervalSince(updated) > Self.staleInterval
        default: false
        }
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func age(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
