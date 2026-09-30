/// Where a surface's contribution to its window title comes from
/// (B-052). An attach surface shows its agent's name, whatever the terminal
/// inside sets via OSC; a title the user set with Change Terminal Title…
/// still wins. Change Tab Title… (`BaseTerminalController.titleOverride`)
/// sits above all of this and is applied by the controller as before.
enum LeoTitleSource: Equatable {
    /// Set by the user with Change Terminal Title….
    case userTitle(String)
    /// The Leo agent attached in the surface.
    case agentName(String)
    /// Ghostty's normal title: whatever the terminal set.
    case terminalTitle(String)

    var title: String {
        switch self {
        case .userTitle(let title), .agentName(let title), .terminalTitle(let title): title
        }
    }

    /// `terminalTitle` is the surface's `title`, which is the user's title
    /// when `isUserSet`. `agentName` is `nil` for anything that isn't an
    /// attach (start page, plain shell).
    static func resolve(terminalTitle: String, isUserSet: Bool, agentName: String?) -> Self {
        if isUserSet { return .userTitle(terminalTitle) }
        guard let agentName, !agentName.isEmpty else { return .terminalTitle(terminalTitle) }
        return .agentName(agentName)
    }
}
