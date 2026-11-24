import Foundation
import Testing

import LeoKit
@testable import Ghostty

/// B-438: the section order is kept in the sidebar preferences, so it
/// survives a relaunch, and plugins coming and going don't disturb it.
@MainActor struct LeoSidebarSectionOrderPersistenceTests {
    private typealias Order = LeoSidebarSectionOrder

    @Test func orderWithoutSectionOrderDecodesToTheDefault() {
        let legacy = Data(#"{"sortOrder":"name","hidesSubagents":true,"expandedPluginSections":["p"]}"#.utf8)
        let prefs = LeoSidebarPreferences.decode(legacy)
        #expect(prefs.sectionOrder.isEmpty)
        #expect(prefs.sortOrder == .name && prefs.hidesSubagents && prefs.expandedPluginSections == ["p"])
    }

    @Test func anUnreadableSectionOrderKeepsTheOtherFields() {
        let bad = Data(#"{"sortOrder":"name","sectionOrder":"agents"}"#.utf8)
        let prefs = LeoSidebarPreferences.decode(bad)
        #expect(prefs.sectionOrder.isEmpty)
        #expect(prefs.sortOrder == .name)
    }

    @Test func orderSurvivesRelaunch() throws {
        let suite = "leo.tests.sectionOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = LeoSidebarModel(preferencesStore: LeoUserDefaultsSidebarPreferencesStore(defaults: defaults))
        first.moveSection(Order.agents, .down, visible: [Order.agents, Order.terminals])

        let relaunched = LeoSidebarModel(preferencesStore: LeoUserDefaultsSidebarPreferencesStore(defaults: defaults))
        let blocks = LeoSidebarTopLevel.blocks(
            machines: [.local], showsTerminals: true, pluginSectionIDs: [], order: relaunched.preferences.sectionOrder
        )
        #expect(blocks == [.terminals, .machine(.local)])
    }

    @Test func installAndUninstallThroughPluginSectionsKeepOrder() {
        let fixture = Fixture(plugins: [plugin("a"), plugin("b")])
        fixture.model.moveSection(fixture.key("b"), onto: Order.agents, visible: fixture.visible)
        #expect(fixture.blocks == [fixture.block("b"), .machine(.local), .terminals, fixture.block("a")])

        fixture.host.plugins.append(plugin("c"))
        #expect(fixture.blocks == [fixture.block("b"), .machine(.local), .terminals, fixture.block("a"), fixture.block("c")])

        fixture.host.plugins.removeAll { $0.id == "studio.test.a" }
        #expect(fixture.blocks == [fixture.block("b"), .machine(.local), .terminals, fixture.block("c")])
    }

    @Test func aDisabledPluginSectionComesBackInItsSlot() {
        let fixture = Fixture(plugins: [plugin("a"), plugin("b")])
        fixture.model.moveSection(fixture.key("b"), onto: Order.agents, visible: fixture.visible)

        // B is turned off; moving A while B isn't listed leaves B's slot alone.
        fixture.host.plugins = [plugin("a"), plugin("b", enabled: false)]
        fixture.model.moveSection(fixture.key("a"), .up, visible: fixture.visible)
        #expect(fixture.blocks == [.machine(.local), fixture.block("a"), .terminals])

        fixture.host.plugins = [plugin("a"), plugin("b")]
        #expect(fixture.blocks == [fixture.block("b"), .machine(.local), fixture.block("a"), .terminals])
    }

    // MARK: Helpers

    private func plugin(_ name: String, enabled: Bool = true) -> LeoPluginInfo {
        LeoPluginTestPlugins.info(
            id: "studio.test.\(name)", name: name, enabled: enabled,
            sections: [LeoPluginSidebarSectionContribution(id: "list", title: name.uppercased())]
        )
    }

    /// A model with plugin sections from a fake host, read the way the
    /// sidebar reads them.
    @MainActor private struct Fixture {
        let model = LeoSidebarModel()
        let host: LeoPluginSlotHostFake

        init(plugins: [LeoPluginInfo]) {
            host = LeoPluginSlotHostFake(plugins: plugins)
            model.pluginSections = LeoPluginSidebarSections(
                host: host, preferences: { [model] in model.preferences }, update: { [model] in model.update($0) }
            )
        }

        func entryID(_ name: String) -> String { LeoSidebarPreferences.pluginSectionKey(plugin: "studio.test.\(name)", section: "list") }
        func key(_ name: String) -> String { Order.pluginKey(entryID(name)) }
        func block(_ name: String) -> LeoSidebarTopLevel.Block { .pluginSection(id: entryID(name)) }

        var blocks: [LeoSidebarTopLevel.Block] {
            LeoSidebarTopLevel.blocks(
                machines: [.local], showsTerminals: true,
                pluginSectionIDs: model.pluginSections?.entries.map(\.id) ?? [], order: model.preferences.sectionOrder
            )
        }

        var visible: [String] { LeoSidebarTopLevel.sectionKeys(of: blocks) }
    }
}
