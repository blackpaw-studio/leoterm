import Foundation
import LeoKit

/// When a window switches itself to Chat: an agent sends a message while
/// that window shows its terminal.
enum LeoChatAutoOpen {
    /// The agent that just sent a live message of any kind (system notices
    /// and permission prompts excluded: a permission mirrors a dialog the
    /// terminal can answer, unlike an ask). Seeds, resyncs and updates to existing messages don't
    /// qualify; history pages don't pass through the relay at all.
    static func agent(sending delivery: LeoChatFeedDelivery) -> LeoAgentID? {
        guard case .event(.message(let message)) = delivery.signal, message.isFromAgent, message.kind != .system, message.kind != .permission else { return nil }
        return LeoAgentID(host: delivery.host, name: message.agent)
    }

    /// Only a window that shows `agent` with its terminal switches: chat
    /// already visible (covering or beside) stays as it is.
    static func shouldOpen(_ agent: LeoAgentID, shown: LeoAgentID?, layout: LeoChatLayout) -> Bool {
        shown == agent && layout == .terminal
    }

    /// A window selecting `agent` with unread messages while it shows the
    /// terminal. Once read (count 0) the remembered choice stands. Unread
    /// counts carry no per-kind breakdown, so a latest agent message that is
    /// a permission prompt (terminal-answerable) approximates "nothing for chat".
    static func shouldOpenOnSelect(unread: Int, layout: LeoChatLayout, latestAgentKind: LeoChatMessage.Kind? = nil) -> Bool {
        unread > 0 && layout == .terminal && latestAgentKind != .permission
    }

    /// Whether an auto-open moves the keyboard to the composer: only when
    /// chat now covers a terminal that held it. A visible terminal keeps
    /// focus, and focus elsewhere (another pane, a field) is left alone.
    static func shouldFocusChat(layout: LeoChatLayout, terminalHadFocus: Bool) -> Bool {
        terminalHadFocus && !layout.isTerminalVisible
    }
}
