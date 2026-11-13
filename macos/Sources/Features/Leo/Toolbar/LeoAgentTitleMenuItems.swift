import Foundation
import LeoKit

/// The agent title menu's entries, in order, with what each is enabled for.
/// They come from the sidebar's right-click menu, minus Delete…, plus
/// Reveal Workspace in Finder and Copy Workspace Path. Pure: the toolbar
/// builds an `NSMenu` from them, and the commands themselves are the Agents
/// menu's actions, so there is no second implementation.
///
/// Enablement reuses `LeoMenuCommands`, the rules the menu bar's validators
/// already use, so the two never disagree.
enum LeoAgentTitleMenuItems {
    enum Command: Equatable {
        case start, stop, restart
        case revealWorkspace, copyWorkspacePath
        case viewLogs, moveTo, rename, appearance, openInNewWindow
    }

    struct Item: Equatable {
        let command: Command
        let title: String
        let isEnabled: Bool
    }

    enum Entry: Equatable {
        case command(Item)
        case separator
    }

    /// What the menu needs to know about the shown agent. `agent` is nil
    /// while none is shown (a plain terminal, the start screen).
    struct Context {
        struct Agent {
            let availability: LeoRowActionAvailability
            let host: LeoHostID
            /// The agent's workspace path as its host reports it.
            let workspace: String?
        }

        let agent: Agent?
        /// The agent's daemon advertises `agent_move`; without it Move To is left out.
        let movesSupported: Bool
        /// The agent's daemon advertises `agent_appearance`; without it Appearance… is left out.
        let appearanceSupported: Bool
    }

    static func entries(for context: Context, fileExists: (String) -> Bool) -> [Entry] {
        let commands = LeoMenuCommands.AgentContext(
            hasLeoSession: true, availability: context.agent?.availability, movesSupported: context.movesSupported)
        func item(_ command: Command, _ title: String, _ isEnabled: Bool) -> Entry {
            .command(Item(command: command, title: title, isEnabled: isEnabled))
        }
        var result: [Entry] = [
            item(.start, "Start", LeoMenuCommands.canStart(commands)),
            item(.stop, "Stop", LeoMenuCommands.canStop(commands)),
            item(.restart, "Restart", LeoMenuCommands.canRestart(commands)),
            .separator,
            item(.revealWorkspace, "Reveal Workspace in Finder", canRevealWorkspace(context.agent, fileExists: fileExists)),
            item(.copyWorkspacePath, "Copy Workspace Path", canCopyWorkspacePath(context.agent)),
            .separator,
            item(.viewLogs, "View Logs", LeoMenuCommands.canViewLogs(commands)),
        ]
        if LeoMenuCommands.showsMoveItems(commands) { result.append(item(.moveTo, "Move To", LeoMenuCommands.canMove(commands))) }
        result.append(item(.rename, "Rename…", LeoMenuCommands.canRename(commands)))
        if context.appearanceSupported { result.append(item(.appearance, "Appearance…", context.agent != nil)) }
        result.append(item(.openInNewWindow, "Open in New Window", LeoMenuCommands.canAttach(commands)))
        return result
    }

    /// Finder shows this Mac's files only: a remote agent's workspace, or
    /// one whose directory is gone, has nothing to reveal.
    static func canRevealWorkspace(_ agent: Context.Agent?, fileExists: (String) -> Bool) -> Bool {
        guard let agent, agent.host == .local, let path = agent.workspace, !path.isEmpty else { return false }
        return fileExists(path)
    }

    /// Any agent with a known workspace, remote included: it copies the path as its host reports it.
    static func canCopyWorkspacePath(_ agent: Context.Agent?) -> Bool {
        guard let agent, let path = agent.workspace else { return false }
        return !path.isEmpty
    }
}
