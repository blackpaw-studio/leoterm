import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// Slot 1's menu entries: the toolbar "⋯" menu lists each plugin view after
/// the messages filter, enabled only for a shown agent, and choosing one opens it.
@MainActor
struct LeoPluginViewMenuTests {
    private static let github = LeoPluginViewEntry(pluginID: "studio.github", pluginName: "GitHub", viewID: "pr", title: "Pull Request", sfSymbol: "arrow.triangle.pull")
    private static let notes = LeoPluginViewEntry(pluginID: "studio.notes", pluginName: "Notes", viewID: "all", title: "Notes", sfSymbol: "doc.text")

    private func makeMenu(
        entries: [LeoPluginViewEntry], hasAgent: Bool = true, open: @escaping (LeoPluginViewEntry) -> Void = { _ in }
    ) -> LeoAgentToolbarMenu {
        LeoAgentToolbarMenu(
            mainMenu: { NSApp.mainMenu },
            messages: .init(knownTasks: { [] }, filter: { nil }, hasAgent: { hasAgent }, select: { _ in }),
            pluginViews: .init(entries: { entries }, open: open))
    }

    private func refresh(_ controller: LeoAgentToolbarMenu) {
        controller.menuNeedsUpdate(controller.menu)
    }

    @Test
    func pluginViewsListAfterTheMessagesFilter() throws {
        let controller = makeMenu(entries: [Self.github, Self.notes])
        refresh(controller)

        let titles = controller.menu.items.map(\.title)
        let messages = try #require(titles.firstIndex(of: "Show Messages"))
        #expect(Array(titles[(messages + 1)...]) == ["", "Pull Request", "Notes"], "a separator, then one item per view")
        #expect(controller.menu.items.last?.image != nil)
    }

    @Test
    func refreshingDoesNotDuplicateTheItems() {
        let controller = makeMenu(entries: [Self.github])
        refresh(controller)
        refresh(controller)
        refresh(controller)

        #expect(controller.menu.items.filter { $0.title == "Pull Request" }.count == 1)
    }

    @Test
    func aPluginThatWentAwayLeavesNoItems() {
        var entries = [Self.github]
        let controller = LeoAgentToolbarMenu(
            mainMenu: { NSApp.mainMenu },
            messages: .init(knownTasks: { [] }, filter: { nil }, hasAgent: { true }, select: { _ in }),
            pluginViews: .init(entries: { entries }, open: { _ in }))
        refresh(controller)
        entries = []
        refresh(controller)

        #expect(!controller.menu.items.contains { $0.title == "Pull Request" })
        #expect(controller.menu.items.last?.isSeparatorItem == false, "no stray separator")
    }

    @Test
    func choosingAnItemOpensThatView() throws {
        var opened: [LeoPluginViewEntry] = []
        let controller = makeMenu(entries: [Self.github, Self.notes]) { opened.append($0) }
        refresh(controller)
        let item = try #require(controller.menu.items.first { $0.title == "Notes" })

        _ = item.target?.perform(item.action, with: item)

        #expect(opened == [Self.notes])
    }

    @Test
    func itemsAreDisabledWithoutAShownAgent() throws {
        let controller = makeMenu(entries: [Self.github], hasAgent: false)
        refresh(controller)
        let item = try #require(controller.menu.items.first { $0.title == "Pull Request" })

        #expect(!controller.validateMenuItem(item))
    }
}
