import Foundation
import GhosttyKit
import Testing

@testable import Ghostty

/// B-273: editor tabs switch and close by menu and keyboard. Agents ▸
/// Show Next/Previous Editor Tab (⇧⌘] / ⇧⌘[) and Close Editor Tab; from
/// the terminal, Ghostty's next_tab/previous_tab switch editor tabs, since
/// a window has no tabs of its own to switch (D-098).
@MainActor
struct LeoEditorTabCommandsTests {
    private func tabs(_ count: Int, in sandbox: LeoFileSandbox) async throws -> LeoEditorTabs {
        let tabs = LeoEditorTabs(makeAccess: { _ in LeoFileAccessor.local() })
        for index in 0 ..< count {
            try await tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("f\(index).txt", "\(index)")))
        }
        return tabs
    }

    @Test func theMenuItemsHaveShortcutsNoOtherItemUses() throws {
        let items = try LeoMenuXib.shortcuts()
        let expected = [
            ("showNextLeoEditorTab:", "Show Next Editor Tab", "⇧⌘]"),
            ("showPreviousLeoEditorTab:", "Show Previous Editor Tab", "⇧⌘["),
        ]
        for (action, title, shortcut) in expected {
            #expect(items.filter { $0.action == action }.map(\.title) == [title])
            #expect(items.filter { $0.shortcut == shortcut }.map(\.action) == [action], "\(shortcut) belongs to \(action) alone")
        }
        #expect(try LeoMenuXib.titles(forAction: "closeLeoEditorTab:") == ["Close Editor Tab"])
    }

    @Test func switchingNeedsTwoTabsAndClosingOne() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            for (count, canSwitch, canClose) in [(0, false, false), (1, false, true), (2, true, true)] {
                let tabs = try await tabs(count, in: sandbox)
                #expect(LeoMenuCommands.canSwitchEditorTabs(tabs) == canSwitch, "\(count) tabs")
                #expect(LeoMenuCommands.canCloseEditorTab(tabs) == canClose, "\(count) tabs")
                await tabs.release()
            }
            #expect(!LeoMenuCommands.canSwitchEditorTabs(nil))
            #expect(!LeoMenuCommands.canCloseEditorTab(nil))
        }
    }

    @Test func ghosttysGotoTabSwitchesEditorTabsWithoutWindowTabs() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let tabs = try await tabs(3, in: sandbox)

            #expect(LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_NEXT, tabs: tabs, hasWindowTabs: false))
            #expect(tabs.document?.displayName == "f0.txt")
            #expect(LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_PREVIOUS, tabs: tabs, hasWindowTabs: false))
            #expect(tabs.document?.displayName == "f2.txt")
            #expect(tabs.focusRequest == 3, "switching from the terminal leaves focus there")
            await tabs.release()
        }
    }

    @Test func ghosttysGotoTabKeepsUpstreamBehaviourOtherwise() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let two = try await tabs(2, in: sandbox)
            #expect(!LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_NEXT, tabs: two, hasWindowTabs: true))
            #expect(!LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_LAST, tabs: two, hasWindowTabs: false))
            #expect(two.document?.displayName == "f1.txt")
            await two.release()

            let one = try await tabs(1, in: sandbox)
            #expect(!LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_NEXT, tabs: one, hasWindowTabs: false))
            #expect(!LeoEditorTabNavigation.gotoTab(GHOSTTY_GOTO_TAB_NEXT, tabs: nil, hasWindowTabs: false))
            await one.release()
        }
    }
}
