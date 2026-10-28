import Foundation

/// B-324: what Delete says for a moved agent's dormant record. The daemon
/// removes the source host's worktree (and its branch only when merged) and
/// leaves the destination alone, so the prompt names the leftover, not the agent.
public enum LeoMovedAgentWording {
    public static let removeLeftoverButton = "Remove"

    public static func removeLeftoverTitle(on source: String, movedTo host: String) -> String {
        "Remove leftover copy on \(source) (the agent lives on \(host))"
    }
}
