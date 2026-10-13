import Foundation
import LeoKit

/// When a window switches itself to Chat: an agent asks for an answer while
/// that window shows its terminal.
enum LeoChatAutoOpen {
    /// The agent that just sent a live, still-open `ask` or `permission`.
    /// Seeds, resyncs and updates never ask; history pages don't pass
    /// through the relay at all.
    static func agent(asking delivery: LeoChatFeedDelivery) -> LeoAgentID? {
        guard case .event(.message(let message)) = delivery.signal, message.isFromAgent, message.isOpen else { return nil }
        return LeoAgentID(host: delivery.host, name: message.agent)
    }

    /// Only a window that shows `agent` with its terminal switches: chat
    /// already visible (covering or beside) stays as it is.
    static func shouldOpen(_ agent: LeoAgentID, shown: LeoAgentID?, layout: LeoChatLayout) -> Bool {
        shown == agent && layout == .terminal
    }
}
