import Testing

@testable import Ghostty

/// With Chat beside the terminal the capsule belongs to the terminal column:
/// centred there, clear of the chat pane, and shrinking through its variants
/// to fit. AppKit centres the toolbar item in the region right of the
/// sidebar, so the item's container pads the capsule's right to move the
/// capsule's centre left. Chat only or terminal only, it stays centred.
struct LeoActivityCapsulePlacementTests {
    private typealias Sizing = LeoActivityCapsuleSizing

    private func placement(window: CGFloat, sidebar: CGFloat, chatWidth: CGFloat?, chrome: CGFloat = 0) -> Sizing.Placement {
        Sizing.placement(
            windowWidth: window, sidebarWidth: sidebar, chatLeadingEdge: chatWidth.map { window - $0 }, leadingChrome: chrome)
    }

    @Test func withoutSideBySideChatTheCapsuleStaysCentredInTheRegion() {
        let result = placement(window: 1400, sidebar: 220, chatWidth: nil)

        #expect(result.layout == Sizing.layout(availableToolbarWidth: 1180, leadingChrome: 0))
        let regionCentre: CGFloat = 220 + 1180 / 2
        #expect(result.minX + result.width / 2 == regionCentre)
        #expect(result.trailingPad == 0)
    }

    @Test func sideBySideTheCapsuleIsCentredOverTheTerminalColumn() {
        let result = placement(window: 1400, sidebar: 220, chatWidth: 448)

        let terminalCentre = (220 + (1400 - 448 - LeoChatLayout.dividerWidth)) / 2
        #expect(abs(result.minX + result.width / 2 - terminalCentre) <= 0.5)
    }

    @Test func sideBySideTheCapsuleKeepsClearOfTheChatPane() {
        let result = placement(window: 1400, sidebar: 220, chatWidth: 448)

        #expect(result.maxX <= 1400 - 448 - Sizing.chatClearance)
        #expect(result.minX >= 220)
    }

    @Test func theContainerStaysCentredInTheRegionWhateverTheOffset() {
        let result = placement(window: 1400, sidebar: 220, chatWidth: 448)

        let containerCentre = result.minX + (result.width + result.trailingPad) / 2
        let regionCentre: CGFloat = 220 + 1180 / 2
        #expect(abs(containerCentre - regionCentre) <= 0.5)
    }

    @Test func aNarrowTerminalColumnDropsTheSubtitleButKeepsTheTitle() {
        // The column is the terminal's 480 pt minimum: too tight for the subtitle.
        let result = placement(window: 1280, sidebar: 220, chatWidth: 1280 - 220 - 480 - LeoChatLayout.dividerWidth)

        #expect(!result.layout.showsSubtitle && result.layout.showsTitle)
    }

    @Test func aWideTerminalColumnKeepsTheSubtitle() {
        let result = placement(window: 1800, sidebar: 220, chatWidth: 448)

        #expect(result.layout.showsSubtitle)
        #expect(result.width <= LeoActivityCapsulePresentation.maxWidth)
    }

    @Test func theCapsuleNeverReachesTheChatPaneAtAnyWidthOrDividerPosition() {
        for window in stride(from: CGFloat(1000), through: 2400, by: 40) {
            for sidebar in [CGFloat(0), 180, 260] {
                let content = window - sidebar
                guard content >= LeoChatLayout.sideBySideMinimumWidth else { continue }
                let widest = content - LeoChatLayout.terminalMinimumWidth - LeoChatLayout.dividerWidth
                for chat in stride(from: LeoChatLayout.chatMinimumWidth, through: widest, by: 30) {
                    let result = placement(window: window, sidebar: sidebar, chatWidth: chat, chrome: sidebar == 0 ? Sizing.collapsedSidebarChrome : 0)
                    #expect(result.maxX <= window - chat - Sizing.chatClearance, "window \(window) sidebar \(sidebar) chat \(chat)")
                    #expect(result.minX >= sidebar, "window \(window) sidebar \(sidebar) chat \(chat)")
                }
            }
        }
    }
}
