import AppKit
import Testing

@testable import Ghostty

/// The toolbar's item model: what is in the default set and in what order,
/// what cannot be removed, what the palette calls each item, where an item
/// may be dropped, and which items fold into the overflow first.
struct LeoAgentToolbarItemsTests {
    typealias Items = LeoAgentToolbarItems

    @Test func theDefaultSetPutsTheTitleLeadingAndTheToolsBeforeTheTrailingGroups() {
        #expect(
            Items.defaultOrder == [
                .leoSidebarToggle, .leoSplitSeparator, .leoTitleMenu, .flexibleSpace, .leoActivity, .flexibleSpace,
                .leoResetZoom, .leoUpdate, .leoFiles, .leoBrowser, .leoAgentPane, .leoViewSwitch, .leoInterrupt, .leoMore,
            ])
    }

    @Test func theTitleTheSwitchAndMoreCannotBeRemoved() {
        #expect(Items.immovable.isSuperset(of: [.leoTitleMenu, .leoViewSwitch, .leoMore]))
    }

    @Test func theAppManagedItemsAreImmovableToo() {
        #expect(Items.immovable.isSuperset(of: [.leoSidebarToggle, .leoSplitSeparator, .leoUpdate, .leoResetZoom]))
    }

    @Test func theUserRemovableItemsAreTheTogglesTheStatusCapsuleAndInterrupt() {
        let removable = Set(Items.defaultOrder).subtracting(Items.immovable).subtracting([.flexibleSpace])
        #expect(removable == [.leoFiles, .leoBrowser, .leoAgentPane, .leoActivity, .leoInterrupt])
    }

    @Test func theSeparatorIsNotInThePalette() {
        #expect(!Items.paletteOrder.contains(.leoSplitSeparator))
        #expect(Items.paletteOrder.contains(.leoFiles))
    }

    @Test func eachPaletteItemHasTheSpecsLabel() {
        let labels = [
            NSToolbarItem.Identifier.leoFiles: "Files", .leoBrowser: "Browser", .leoAgentPane: "Agent Pane",
            .leoActivity: "Status", .leoViewSwitch: "View", .leoInterrupt: "Interrupt", .leoMore: "More",
        ]
        for (identifier, label) in labels { #expect(Items.paletteLabel(for: identifier) == label) }
    }

    @Test func everyItemInThePaletteHasATooltipAndALabel() {
        for identifier in Items.paletteOrder {
            #expect(Items.paletteLabel(for: identifier) != nil)
            #expect(Items.tooltip(for: identifier)?.isEmpty == false)
        }
    }

    @Test func nothingMayBeDroppedBeforeTheTitle() {
        let current: [NSToolbarItem.Identifier] = [.leoSidebarToggle, .leoSplitSeparator, .leoTitleMenu, .leoViewSwitch]
        #expect(!Items.canInsert(.leoFiles, at: 0, in: current))
        #expect(!Items.canInsert(.leoFiles, at: 2, in: current))
        #expect(Items.canInsert(.leoFiles, at: 3, in: current))
        #expect(Items.canInsert(.leoFiles, at: 4, in: current))
    }

    @Test func anythingMayBeDroppedWhileTheTitleIsNotThere() {
        #expect(Items.canInsert(.leoFiles, at: 0, in: [.leoViewSwitch]))
    }

    @Test func theTogglesFoldFirstThenInterruptAndTheRestLast() {
        for toggle in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane] {
            #expect(Items.visibilityPriority(for: toggle) == .low)
        }
        #expect(Items.visibilityPriority(for: .leoInterrupt) == .standard)
        for id in [NSToolbarItem.Identifier.leoTitleMenu, .leoViewSwitch, .leoMore] {
            #expect(Items.visibilityPriority(for: id) == .user)
        }
    }
}
