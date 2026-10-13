import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Terminal | Chat switch: how the content area right of the sidebar is
/// shared between the terminal column and the chat pane.
struct LeoChatLayoutTests {
    private static let threshold = LeoChatLayout.sideBySideMinimumWidth

    @Test func clickingChatWhileTheTerminalShowsOpensChat() {
        #expect(LeoChatLayout.terminal.choice(afterClicking: .chat) == .chat)
    }

    @Test(arguments: [LeoChatLayout.chatReplacingTerminal, .sideBySide])
    func clickingChatWhileChatShowsClosesIt(layout: LeoChatLayout) {
        #expect(layout.choice(afterClicking: .chat) == .terminal)
    }

    @Test(arguments: [LeoChatLayout.terminal, .chatReplacingTerminal, .sideBySide])
    func clickingTerminalAlwaysShowsTheTerminalAlone(layout: LeoChatLayout) {
        #expect(layout.choice(afterClicking: .terminal) == .terminal)
    }

    @Test(arguments: [0, 800, threshold - 1, threshold, 1300, 2400])
    func terminalChoiceShowsOnlyTheTerminal(width: CGFloat) {
        #expect(LeoChatLayout(contentWidth: width, choice: .terminal) == .terminal)
    }

    @Test(arguments: [0, 627, 800, threshold - 0.5])
    func chatBelowTheThresholdReplacesTheTerminal(width: CGFloat) {
        let layout = LeoChatLayout(contentWidth: width, choice: .chat)
        #expect(layout == .chatReplacingTerminal)
        #expect(layout.showsChat && !layout.isTerminalVisible)
    }

    @Test func chatAtTheThresholdShowsBothSideBySide() {
        let layout = LeoChatLayout(contentWidth: Self.threshold, choice: .chat)
        guard case .sideBySide = layout else {
            Issue.record("expected side by side at the threshold, got \(layout)")
            return
        }
        #expect(layout.showsChat && layout.isTerminalVisible)
    }

    @Test(arguments: [threshold, 1100, 1300, 1600, 2400, 5000])
    func sideBySideKeepsBothPanesAtOrAboveTheirMinimums(width: CGFloat) {
        let layout = LeoChatLayout(contentWidth: width, choice: .chat)
        let chat = layout.chatWidth(in: width)
        let terminal = layout.terminalWidth(in: width)
        #expect(chat >= LeoChatLayout.chatMinimumWidth)
        #expect(chat <= LeoChatLayout.chatMaximumWidth)
        #expect(terminal >= LeoChatLayout.terminalMinimumWidth)
        #expect(terminal + LeoChatLayout.dividerWidth + chat == width)
    }

    @Test func sideBySideChatGrowsWithTheWindowUpToItsMaximum() {
        let width = { LeoChatLayout(contentWidth: $0, choice: .chat).chatWidth(in: $0) }
        #expect(width(1300) > width(Self.threshold))
        #expect(width(5000) == LeoChatLayout.chatMaximumWidth)
    }

    @Test func replacedTerminalKeepsTheFullWidthUnderTheChat() {
        // The terminal stays laid out at full size so tmux never reflows
        // while it's hidden behind the chat.
        let layout = LeoChatLayout(contentWidth: 700, choice: .chat)
        #expect(layout.terminalWidth(in: 700) == 700)
        #expect(layout.chatWidth(in: 700) == 700)
    }

    @Test func terminalOnlyGivesTheChatNoWidth() {
        let layout = LeoChatLayout(contentWidth: 1300, choice: .terminal)
        #expect(layout.terminalWidth(in: 1300) == 1300)
        #expect(layout.chatWidth(in: 1300) == 0)
        #expect(!layout.showsChat && layout.isTerminalVisible)
    }

    @Test func nonFiniteWidthFallsBackToReplacing() {
        #expect(LeoChatLayout(contentWidth: .nan, choice: .chat) == .chatReplacingTerminal)
        #expect(LeoChatLayout(contentWidth: -.infinity, choice: .chat) == .chatReplacingTerminal)
    }

    @Test func switchShowsWhatIsOnScreen() {
        #expect(LeoChatLayout.terminal.activeSegments == [.terminal])
        #expect(LeoChatLayout.chatReplacingTerminal.activeSegments == [.chat])
        #expect(LeoChatLayout(contentWidth: 1300, choice: .chat).activeSegments == [.terminal, .chat])
    }

    @Test func choicesAreRememberedPerAgentAndDefaultToTerminal() {
        let alpha = LeoAgentID(host: .local, name: "alpha")
        let beta = LeoAgentID(host: .local, name: "beta")
        let choices = LeoAgentViewChoices().setting(.chat, for: alpha)
        #expect(choices[alpha] == .chat)
        #expect(choices[beta] == .terminal)
        #expect(choices.setting(.terminal, for: alpha)[alpha] == .terminal)
        #expect(LeoAgentViewChoices()[alpha] == .terminal)
    }
}
