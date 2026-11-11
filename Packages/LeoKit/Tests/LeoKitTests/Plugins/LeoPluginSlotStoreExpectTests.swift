import Testing

@testable import LeoKit

@MainActor struct LeoPluginSlotStoreExpectTests {
    private let plugin = "studio.blackpaw.demo"
    private let palette = LeoPluginSlotID.palette(commandID: "go")

    @Test func reopeningACommandShowsLoadingNotItsPreviousPageOrPushedViews() throws {
        let store = LeoPluginSlotStore()
        let key = LeoPluginSlotKey(pluginID: plugin, slot: palette)
        store.render(pluginID: plugin, slot: palette, root: try LeoPluginSlotRoot(nodes: [.loading(.init(message: "old"))]))
        store.push(.loading(.init(message: "pushed")), onto: key)

        store.expect(pluginID: plugin, slot: palette)

        #expect(store.state(key) == .loading)
        #expect(store.pushed[key] == nil)
    }

    @Test func expectingAnotherKindOfSlotKeepsItsRenderedTree() throws {
        let store = LeoPluginSlotStore()
        let section = LeoPluginSlotID.section(id: "issues")
        let root = try LeoPluginSlotRoot(nodes: [.loading(.init(message: "x"))])
        store.render(pluginID: plugin, slot: section, root: root)

        store.expect(pluginID: plugin, slot: section)

        #expect(store.state(pluginID: plugin, slot: section) == .tree(root))
    }
}
