import LeoFeatures
import LeoKit
import UIKit

extension AgentBriefRow.Kind {
    /// The small label above a row's text.
    var title: String {
        switch self {
        case .goal: String(localized: "Goal")
        case .status: String(localized: "Status")
        case .decision: String(localized: "Decided")
        case .open: String(localized: "Open")
        case .updated: ""
        }
    }
}

extension Agent {
    /// The brief ready to show; nil hides the section. Staleness compares the
    /// brief's age with the agent's last activity.
    func briefPresentation(now: Date = Date()) -> LeoAgentBriefPresentation? {
        LeoAgentBriefPresentation(brief: brief, lastActivity: lastActivityDate, now: now)
    }

    private var lastActivityDate: Date? {
        guard let text = lastActivityAt else { return nil }
        return (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
