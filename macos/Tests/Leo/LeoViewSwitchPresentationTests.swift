import Testing

@testable import Ghostty

/// What the toolbar's Terminal | Chat switch shows, and how a click maps back to a view choice.
struct LeoViewSwitchPresentationTests {
    @Test func noAgentDisablesTheSwitchWithNothingLit() {
        let presentation = LeoViewSwitchPresentation(layout: nil, unreadCount: 3)
        #expect(!presentation.isEnabled)
        #expect(presentation.selected.isEmpty)
        #expect(!presentation.showsUnreadDot)
        #expect(presentation.chatAccessibilityLabel == "Chat")
    }

    @Test func terminalAloneLightsTheTerminalSegment() {
        let presentation = LeoViewSwitchPresentation(layout: .terminal, unreadCount: 0)
        #expect(presentation.isEnabled)
        #expect(presentation.selected == [.terminal])
    }

    @Test func chatReplacingTerminalLightsChatAlone() {
        #expect(LeoViewSwitchPresentation(layout: .chatReplacingTerminal, unreadCount: 0).selected == [.chat])
    }

    @Test func sideBySideLightsBothSegments() {
        #expect(LeoViewSwitchPresentation(layout: .sideBySide, unreadCount: 0).selected == [.terminal, .chat])
    }

    @Test func unreadShowsADotWhileChatIsOutOfSight() {
        let presentation = LeoViewSwitchPresentation(layout: .terminal, unreadCount: 2)
        #expect(presentation.showsUnreadDot)
    }

    @Test(arguments: [LeoChatLayout.chatReplacingTerminal, .sideBySide])
    func noDotWhileChatShows(layout: LeoChatLayout) {
        let presentation = LeoViewSwitchPresentation(layout: layout, unreadCount: 5)
        #expect(!presentation.showsUnreadDot)
        #expect(presentation.chatAccessibilityLabel == "Chat")
    }

    @Test(arguments: [(0, "Chat"), (1, "Chat, 1 unread"), (12, "Chat, 12 unread")])
    func voiceOverLabelCarriesTheUnreadCount(count: Int, label: String) {
        #expect(LeoViewSwitchPresentation(layout: .terminal, unreadCount: count).chatAccessibilityLabel == label)
    }

    @Test func fixedLabelsAndTooltips() {
        #expect(LeoViewSwitchPresentation.groupLabel == "View")
        #expect(LeoViewSwitchPresentation.tooltips == ["Terminal", "Chat"])
        #expect(LeoViewSwitchPresentation.choices == [.terminal, .chat])
    }

    @Test func everySegmentShowsASymbolAndANounLabel() {
        #expect(LeoViewSwitchPresentation.segmentLabels == ["Terminal", "Chat"])
        #expect(LeoViewSwitchPresentation.segmentSymbols == ["terminal", "bubble.left"])
        #expect(LeoViewSwitchPresentation.segmentLabels.count == LeoViewSwitchPresentation.choices.count)
    }

    @Test func theUnreadCountStaysOnChatAsADotAndNeverChangesTheVisibleLabel() {
        let unread = LeoViewSwitchPresentation(layout: .terminal, unreadCount: 4)
        #expect(unread.showsUnreadDot)
        #expect(unread.chatAccessibilityLabel == "Chat, 4 unread")
        #expect(LeoViewSwitchPresentation.segmentLabels[1] == "Chat")
    }

    @Test func clickingChatWhileOnlyTerminalShowsPicksChat() {
        let presentation = LeoViewSwitchPresentation(layout: .terminal, unreadCount: 0)
        #expect(presentation.clicked(segmentStates: [true, true]) == .chat)
    }

    @Test func clickingChatWhileSideBySidePicksChatToClose() {
        let presentation = LeoViewSwitchPresentation(layout: .sideBySide, unreadCount: 0)
        #expect(presentation.clicked(segmentStates: [true, false]) == .chat)
    }

    @Test func clickingTerminalWhileChatAlonePicksTerminal() {
        let presentation = LeoViewSwitchPresentation(layout: .chatReplacingTerminal, unreadCount: 0)
        #expect(presentation.clicked(segmentStates: [true, true]) == .terminal)
    }

    @Test func aStateEqualToWhatShowsIsNotAClick() {
        let presentation = LeoViewSwitchPresentation(layout: .terminal, unreadCount: 0)
        #expect(presentation.clicked(segmentStates: [true, false]) == nil)
    }
}
