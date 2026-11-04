import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The toolbar's "⋯" menu: the Agents menu's control actions with the same
/// shortcuts, and "Show Messages ▸" over the chat's task filter.
@MainActor
struct LeoAgentToolbarMenuTests {
    private func makeMenu(
        knownTasks: Set<String> = [], filter: String? = nil, hasAgent: Bool = true,
        select: @escaping (String?) -> Void = { _ in }
    ) -> LeoAgentToolbarMenu {
        LeoAgentToolbarMenu(
            mainMenu: { NSApp.mainMenu },
            messages: .init(knownTasks: { knownTasks }, filter: { filter }, hasAgent: { hasAgent }, select: select))
    }

    private func liveItem(_ action: Selector) throws -> NSMenuItem {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == action { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return try #require(find(NSApp.mainMenu), "the Agents menu has no \(action)")
    }

    @Test(arguments: LeoAgentToolbarMenu.controlActions.map(NSStringFromSelector))
    func controlItemsKeepTheAgentsMenuTitleAndShortcut(_ name: String) throws {
        let action = NSSelectorFromString(name)
        let live = try liveItem(action)
        let menu = makeMenu().menu
        let item = try #require(menu.items.first { $0.action == action }, "no item for \(action)")

        #expect(item.title == live.title)
        #expect(item.keyEquivalent == live.keyEquivalent)
        #expect(item.keyEquivalentModifierMask == live.keyEquivalentModifierMask)
        #expect(item.target == nil, "a nil target goes down the responder chain, like the menu bar's")
    }

    @Test func theMenuHoldsInterruptCompactClearThenShowMessages() {
        let titles = makeMenu().menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        #expect(titles.count == 4)
        #expect(titles.last == "Show Messages")
    }

    @Test func showMessagesListsAllMessagesThenTheKnownTasksSorted() {
        let entries = LeoMessagesFilterMenu.entries(knownTasks: ["lint", "build"], filter: nil)

        #expect(entries.map(\.title) == ["All Messages", "build", "lint"])
        #expect(entries.map(\.isChecked) == [true, false, false])
    }

    @Test func theCurrentFilterIsChecked() {
        let entries = LeoMessagesFilterMenu.entries(knownTasks: ["lint", "build"], filter: "lint")

        #expect(entries.map(\.isChecked) == [false, false, true])
    }

    @Test func aFilterNoLongerKnownStaysListedSoItCanBeCleared() {
        let entries = LeoMessagesFilterMenu.entries(knownTasks: [], filter: "gone")

        #expect(entries.map(\.title) == ["All Messages", "gone"])
        #expect(entries.last?.isChecked == true)
    }

    @Test func theSubmenuIsRebuiltFromTheKnownTasksWhenItOpens() throws {
        var known: Set<String> = []
        let controller = LeoAgentToolbarMenu(
            mainMenu: { NSApp.mainMenu },
            messages: .init(knownTasks: { known }, filter: { nil }, hasAgent: { true }, select: { _ in }))
        let submenu = try #require(controller.menu.items.last?.submenu)

        known = ["build"]
        controller.menuNeedsUpdate(submenu)

        #expect(submenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["All Messages", "build"])
    }

    @Test func pickingATaskReportsIt() throws {
        var picked: [String?] = []
        let controller = makeMenu(knownTasks: ["build"]) { picked.append($0) }
        let submenu = try #require(controller.menu.items.last?.submenu)
        controller.menuNeedsUpdate(submenu)

        let item = try #require(submenu.items.last)
        _ = item.target?.perform(item.action, with: item)
        let all = try #require(submenu.items.first)
        _ = all.target?.perform(all.action, with: all)

        #expect(picked == ["build", nil])
    }

    @Test func showMessagesIsDisabledWithNoAgentSelected() throws {
        let controller = makeMenu(hasAgent: false)
        controller.menuNeedsUpdate(controller.menu)

        #expect(try #require(controller.menu.items.last).isEnabled == false)
    }
}
