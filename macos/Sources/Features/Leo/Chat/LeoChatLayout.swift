import CoreGraphics
import LeoKit

/// What an agent's Terminal | Chat switch asks for.
enum LeoAgentViewChoice: Equatable, Sendable {
    case terminal
    case chat
}

/// How the content area right of the sidebar is shared between the
/// terminal column and the chat pane. Too narrow for both, chat replaces the
/// terminal; the terminal stays laid out at full width underneath, so its
/// surface and tmux size never change while it's hidden.
enum LeoChatLayout: Equatable {
    case terminal
    case chatReplacingTerminal
    case sideBySide

    /// The narrowest content area that shows chat beside the terminal.
    static let sideBySideMinimumWidth: CGFloat = 1000
    static let terminalMinimumWidth: CGFloat = 480
    static let chatMinimumWidth: CGFloat = 320
    static let chatMaximumWidth: CGFloat = 560
    /// Side by side, the chat's share of the content area before clamping.
    static let chatWidthFraction: CGFloat = 0.38
    static let dividerWidth: CGFloat = 1

    init(contentWidth: CGFloat, choice: LeoAgentViewChoice) {
        switch choice {
        case .terminal: self = .terminal
        case .chat:
            // A NaN width compares false, so it falls back to replacing.
            self = contentWidth >= Self.sideBySideMinimumWidth ? .sideBySide : .chatReplacingTerminal
        }
    }

    var showsChat: Bool { self != .terminal }
    var isTerminalVisible: Bool { self != .chatReplacingTerminal }

    /// The switch's lit segments: both when side by side.
    var activeSegments: Set<LeoAgentViewChoice> {
        switch self {
        case .terminal: [.terminal]
        case .chatReplacingTerminal: [.chat]
        case .sideBySide: [.terminal, .chat]
        }
    }

    func chatWidth(in contentWidth: CGFloat) -> CGFloat {
        switch self {
        case .terminal: return 0
        case .chatReplacingTerminal: return contentWidth
        case .sideBySide:
            let ceiling = min(Self.chatMaximumWidth, contentWidth - Self.terminalMinimumWidth - Self.dividerWidth)
            return max(Self.chatMinimumWidth, min(ceiling, (contentWidth * Self.chatWidthFraction).rounded()))
        }
    }

    func terminalWidth(in contentWidth: CGFloat) -> CGFloat {
        switch self {
        case .terminal, .chatReplacingTerminal: contentWidth
        case .sideBySide: contentWidth - Self.dividerWidth - chatWidth(in: contentWidth)
        }
    }
}

/// Where a request to focus an agent's terminal should actually land.
enum LeoFocusTarget: Equatable {
    case terminal
    case chatComposer

    /// A terminal covered by chat must not take the keyboard: keystrokes
    /// would go to an agent nobody can see, so the composer takes it.
    init(for layout: LeoChatLayout) {
        self = layout.isTerminalVisible ? .terminal : .chatComposer
    }
}

/// Each agent's switch position, remembered for the app session.
struct LeoAgentViewChoices: Equatable {
    private var choices: [LeoAgentID: LeoAgentViewChoice] = [:]

    subscript(agent: LeoAgentID) -> LeoAgentViewChoice { choices[agent] ?? .terminal }

    func setting(_ choice: LeoAgentViewChoice, for agent: LeoAgentID) -> Self {
        var copy = self
        copy.choices[agent] = choice
        return copy
    }
}
