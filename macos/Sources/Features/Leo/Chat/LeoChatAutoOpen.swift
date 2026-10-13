import Foundation
import LeoKit

/// When a window switches itself to Chat: an agent sends a message while
/// that window shows its terminal.
enum LeoChatAutoOpen {
    /// The agent that just sent a live message of any kind (system notices
    /// excluded). Seeds, resyncs and updates to existing messages don't
    /// qualify; history pages don't pass through the relay at all.
    static func agent(sending delivery: LeoChatFeedDelivery) -> LeoAgentID? {
        guard case .event(.message(let message)) = delivery.signal, message.isFromAgent, message.kind != .system else { return nil }
        return LeoAgentID(host: delivery.host, name: message.agent)
    }

    /// Only a window that shows `agent` with its terminal switches: chat
    /// already visible (covering or beside) stays as it is.
    static func shouldOpen(_ agent: LeoAgentID, shown: LeoAgentID?, layout: LeoChatLayout) -> Bool {
        shown == agent && layout == .terminal
    }
}
