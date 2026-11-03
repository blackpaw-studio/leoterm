import Foundation
import LeoKit

/// Whether the user is looking at an agent right now, as the chat host
/// decides what is shown: the key window of this app is frontmost with that
/// agent actionably selected and no terminal tab covering it.
enum LeoProgressWatching {
    static func isWatching(_ agent: LeoAgentRow.ID, isAppActive: Bool, showsTerminalTab: Bool, selected: LeoAgentRow.ID?) -> Bool {
        isAppActive && !showsTerminalTab && selected == agent
    }
}
