import Foundation

/// The Service pane's timings, shared by both platforms.
public enum LeoServicePane {
    /// Lines of the daemon's log each poll reads.
    public static let logLines = 200
    public static let logInterval = Duration.seconds(2)
    public static let restartPollInterval = Duration.seconds(1)
    /// Polls that find the daemon unreachable before giving up on it.
    public static let defaultMaxRestartPolls = 60
    /// The whole restart wait. A graceful restart lets busy agents drain for
    /// up to ten minutes before the daemon exits; this adds margin.
    public static let defaultRestartDeadline: TimeInterval = 12 * 60
}

/// What the Service pane says, from every place it says it.
public enum LeoServiceText {
    /// What the Restart All Agents confirmation says.
    public static func agentsRestartMessage(running: Int?) -> String {
        guard let running else { return "Every running agent will restart and lose the current turn." }
        return "\(running) running agent\(running == 1 ? "" : "s") will restart and lose the current turn."
    }

    public static func summary(of result: LeoAgentsRestartResult) -> String {
        let count = result.restarted.count
        var parts = ["Restarted \(count) agent\(count == 1 ? "" : "s")."]
        if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped.") }
        if let failure = failureText(of: result) { parts.append(failure) }
        return parts.joined(separator: " ")
    }

    public static func failureText(of result: LeoAgentsRestartResult) -> String? {
        guard result.hasFailures else { return nil }
        return "Couldn’t restart " + result.failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "."
    }

    /// The restart wait ran out. `afterDown`: the daemon was unreachable, so
    /// the connection is the thing to check; otherwise it never stopped
    /// answering and is still waiting for busy agents.
    public static func gaveUp(afterDown: Bool, machine: String) -> String {
        afterDown
            ? "leo on \(machine) hasn’t come back yet. Check its connection under Machines."
            : "leo on \(machine) is still waiting for busy agents to pause. The restart may still go through."
    }
}
