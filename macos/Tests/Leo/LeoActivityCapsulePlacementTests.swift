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

    @Test func sideBySideTheCapsuleIsCentredOverTheTerminalColumnWhereTheTrailingItemsStillFit() {
        // Only a very wide window keeps every trailing item beside the padded container.
        let result = placement(window: 3000, sidebar: 220, chatWidth: 448)

        let terminalCentre = (220 + (3000 - 448 - LeoChatLayout.dividerWidth)) / 2
        #expect(abs(result.minX + result.width / 2 - terminalCentre) <= 0.5)
    }

    /// The trailing items are always right-aligned over the chat pane, and the
    /// padded container that centres the capsule on the terminal column reaches
    /// as far right as the capsule plus the chat pane's width, so it covers the
    /// room they need: the toggles and Interrupt can never fit beside it. Where
    /// they fit at all, the capsule flows between the title and them instead.
    @Test func sideBySideTheTogglesAndInterruptStayWhereTheyFit() {
        for (window, chat) in [(CGFloat(1660), CGFloat(530)), (1400, 440), (1200, 400)] {
            let result = placement(window: window, sidebar: 260, chatWidth: chat)

            #expect(result.layout.showsToggles && result.layout.showsInterrupt, "window \(window)")
            #expect(!result.layout.isCentered && result.trailingPad == 0, "window \(window)")
            #expect(result.maxX <= window - chat - Sizing.chatClearance, "window \(window)")
            #expect(result.minX >= 260 && result.width >= Sizing.minimumWidth, "window \(window)")
            // Clear of the trailing groups it keeps beside it.
            #expect(result.maxX <= window - Sizing.trailingGroupsReserve, "window \(window)")
        }
    }

    @Test func sideBySideTheCapsuleKeepsClearOfTheChatPane() {
        let result = placement(window: 1400, sidebar: 220, chatWidth: 448)

        #expect(result.maxX <= 1400 - 448 - Sizing.chatClearance)
        #expect(result.minX >= 220)
    }

    @Test func theContainerStaysCentredInTheRegionWhateverTheOffset() {
        // Too narrow to flow between the title and the trailing groups: the centred container, with items shed.
        let result = placement(window: 900, sidebar: 220, chatWidth: 300)

        let containerCentre = result.minX + (result.width + result.trailingPad) / 2
        let regionCentre: CGFloat = 220 + 680 / 2
        #expect(abs(containerCentre - regionCentre) <= 0.5)
    }

    @Test func aNarrowTerminalColumnDropsTheSubtitleButKeepsTheTitle() {
        // The column is the terminal's 480 pt minimum: too tight for the subtitle.
        // Too narrow to flow between the title and the trailing groups, so the column is the room.
        let result = placement(window: 900, sidebar: 220, chatWidth: 900 - 220 - 480 - LeoChatLayout.dividerWidth)

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
                    // The container's padded right edge must clear the switch and "⋯", which never fold.
                    if result.width > Sizing.compactWidth {
                        let containerRight = result.minX + result.width + result.trailingPad
                        #expect(
                            containerRight <= window - Sizing.trailingReserveMinimal + 0.5,
                            "window \(window) sidebar \(sidebar) chat \(chat) right \(containerRight)")
                    }
                }
            }
        }
    }

    @Test func sideBySideTheTogglesFoldOnlyWhereTheyCannotFitAtAll() {
        func shown(window: CGFloat) -> Sizing.Layout { placement(window: window, sidebar: 220, chatWidth: 300).layout }
        #expect(shown(window: 1400).showsToggles && shown(window: 1400).showsInterrupt)
        // Too narrow for the title, the capsule's floor and the trailing groups: the padded, centred container, items shed.
        #expect(!shown(window: 900).showsToggles)
    }

    @Test func sideBySideThePillNeedsRoomRightOfTheCapsuleElseItIsHidden() {
        // The pill sits with the trailing groups, over the chat pane; a pill with no room there
        // would fold into AppKit's overflow, and its chevron takes the capsule's room too.
        func shown(window: CGFloat, pill: CGFloat) -> Sizing.Placement {
            Sizing.placement(
                windowWidth: window, sidebarWidth: 220, chatLeadingEdge: window - 448, leadingChrome: 0, trailingReserve: pill)
        }
        #expect(shown(window: 1400, pill: 200).layout.showsUpdateItem)
        #expect(shown(window: 1400, pill: 200).layout.showsToggles)
        #expect(!shown(window: 900, pill: 200).layout.showsUpdateItem)
        #expect(!shown(window: 900, pill: 200).layout.showsToggles)
        #expect(shown(window: 3200, pill: 200).layout.showsUpdateItem)
        #expect(!shown(window: 3200, pill: 0).layout.showsUpdateItem)
    }
}
