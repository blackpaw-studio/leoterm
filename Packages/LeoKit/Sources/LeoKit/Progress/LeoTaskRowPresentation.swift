import Foundation

/// What the trailing slot of an agent row draws for its tasks. The platform
/// draws it (a pie, a spinner, a glyph); the choice lives here so Mac and iOS
/// agree.
public enum LeoTaskIndicator: Equatable, Sendable {
    /// A live task. `nil` is the indeterminate spinner.
    case progress(fraction: Double?)
    /// A stale task and nothing live: muted and still. `nil` is an empty pie.
    case stalled(fraction: Double?)
    /// An undismissed failed task.
    case failed
}

public struct LeoTaskRowSummary: Equatable, Sendable {
    /// `nil`: the platform's own trailing content (the elapsed time).
    public let indicator: LeoTaskIndicator?
    /// `nil`: fall through to the next detail-line source.
    public let detail: String?
    /// The tail of `detail` that must stay whole when the line is too long
    /// (" · no update for 21m"): a cell truncates the title, not this. `nil`
    /// when `detail` has no such tail.
    public let detailSuffix: String?
    /// The full one-line summary of the primary task, plus the others.
    public let tooltip: String
    /// "Build Leo.app, 62 percent", "In progress", "Stalled" or "Failed".
    public let spokenValue: String?
}

public enum LeoTaskRowPresentation {
    /// Returns nil only when there are no tasks. `etaAt` is keyed by task id.
    /// `agentIsInError` suppresses the failed glyph: the row's leading symbol
    /// already shows the failure.
    public static func summary(
        _ tasks: [LeoAgentTask], etaAt: [String: Date], agentIsInError: Bool, now: Date
    ) -> LeoTaskRowSummary? {
        guard let primary = LeoAgentTasks.primary(tasks) else { return nil }
        let others = tasks.filter { $0.id != primary.id }
        let live = tasks.filter { $0.isRunning && !$0.stale }
        let stale = tasks.filter { $0.isRunning && $0.stale }
        let title = runningTitle(primary, otherRunning: others.filter(\.isRunning).count)

        var tooltip = LeoTaskText.summary(primary, etaAt: etaAt[primary.id], now: now)
        if !others.isEmpty { tooltip += ", \(others.count) more" }

        let liveFraction = meanFraction(live)
        let indicator: LeoTaskIndicator?
        let spoken: String?
        if let livePrimary = LeoAgentTasks.primary(live) {
            indicator = .progress(fraction: liveFraction)
            // Named for the live tasks that decide the indicator, not for a
            // failed primary that only owns the detail line.
            let liveTitle = runningTitle(livePrimary, otherRunning: tasks.filter { $0.isRunning && $0.id != livePrimary.id }.count)
            spoken = liveFraction.map { "\(liveTitle), \(Int(($0 * 100).rounded())) percent" } ?? "In progress"
        } else if let latest = stale.max(by: { $0.updatedAt < $1.updatedAt }) {
            indicator = .stalled(fraction: fraction(of: latest))
            spoken = "Stalled"
        } else if primary.state == .failed {
            indicator = agentIsInError ? nil : .failed
            spoken = "Failed"
        } else {
            indicator = nil
            spoken = nil
        }

        let suffix = staleSuffix(primary, now: now)
        let detail = suffix.map { primary.title + $0 } ?? detail(primary, title: title)
        return LeoTaskRowSummary(indicator: indicator, detail: detail, detailSuffix: suffix, tooltip: tooltip, spokenValue: spoken)
    }

    private static func detail(_ primary: LeoAgentTask, title: String) -> String? {
        switch primary.state {
        case .running: title
        case .failed: "Failed: \(primary.title)"
        case .succeeded, .cancelled: nil
        }
    }

    private static func staleSuffix(_ primary: LeoAgentTask, now: Date) -> String? {
        guard primary.isRunning, primary.stale else { return nil }
        return " · no update for \(LeoTaskText.duration(now.timeIntervalSince(primary.updatedAt)))"
    }

    private static func runningTitle(_ primary: LeoAgentTask, otherRunning: Int) -> String {
        guard primary.isRunning, otherRunning > 0 else { return primary.title }
        return "\(primary.title) and \(otherRunning) more"
    }

    private static func fraction(of task: LeoAgentTask) -> Double? {
        guard task.mode == .determinate, let percent = task.percent else { return nil }
        return min(max(percent, 0), 100) / 100
    }

    private static func meanFraction(_ tasks: [LeoAgentTask]) -> Double? {
        let fractions = tasks.compactMap(fraction(of:))
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }
}
