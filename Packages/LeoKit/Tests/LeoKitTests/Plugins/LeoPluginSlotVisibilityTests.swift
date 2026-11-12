import Testing

@testable import LeoKit

struct LeoPluginSlotVisibilityTests {
    private func key(_ section: String, plugin: String = "p") -> LeoPluginSlotKey {
        LeoPluginSlotKey(pluginID: plugin, slot: .section(id: section))
    }

    @Test func theFirstVisibleSlotShowsThePluginAndTheLastOneToLeaveHidesIt() {
        var visibility = LeoPluginSlotVisibility()
        #expect(visibility.set(key("a"), visible: true) == true)
        #expect(visibility.set(key("b"), visible: true) == nil)
        #expect(visibility.set(key("a"), visible: false) == nil)
        #expect(visibility.set(key("b"), visible: false) == false)
    }

    @Test func closingOneSlotDoesNotHideAPluginWhoseOtherSlotIsStillOnScreen() {
        var visibility = LeoPluginSlotVisibility()
        let view = LeoPluginSlotKey(pluginID: "p", slot: .view(viewID: "v", agent: .init(machine: "m", name: "n")))
        let palette = LeoPluginSlotKey(pluginID: "p", slot: .palette(commandID: "go"))
        _ = visibility.set(view, visible: true)
        _ = visibility.set(palette, visible: true)

        #expect(visibility.set(palette, visible: false) == nil)
        #expect(visibility.isVisible(plugin: "p"))
    }

    @Test func theSameSlotShownTwiceStaysVisibleUntilBothLeave() {
        var visibility = LeoPluginSlotVisibility()
        _ = visibility.set(key("a"), visible: true)
        _ = visibility.set(key("a"), visible: true)

        #expect(visibility.set(key("a"), visible: false) == nil)
        #expect(visibility.set(key("a"), visible: false) == false)
    }

    @Test func pluginsAreCountedSeparately() {
        var visibility = LeoPluginSlotVisibility()
        _ = visibility.set(key("a", plugin: "p1"), visible: true)

        #expect(visibility.set(key("a", plugin: "p2"), visible: true) == true)
        #expect(visibility.set(key("a", plugin: "p1"), visible: false) == false)
        #expect(visibility.isVisible(plugin: "p2"))
    }

    @Test func aLeaveWithoutAnAppearanceChangesNothing() {
        var visibility = LeoPluginSlotVisibility()
        #expect(visibility.set(key("a"), visible: false) == nil)
        #expect(visibility.set(key("a"), visible: true) == true)
    }

    @Test func aPaneIsVisibleOnlyWhileOneOfThePluginsPaneSlotsIs() {
        var visibility = LeoPluginSlotVisibility()
        let agent = LeoPluginAgentRef(machine: "m", name: "n")
        let summary = LeoPluginSlotKey(pluginID: "p", slot: .pane(id: "status", part: .summary, agent: agent))
        let body = LeoPluginSlotKey(pluginID: "p", slot: .pane(id: "status", part: .body, agent: agent))
        let view = LeoPluginSlotKey(pluginID: "p", slot: .view(viewID: "v", agent: agent))

        _ = visibility.set(view, visible: true)
        #expect(visibility.isVisible(plugin: "p"))
        #expect(!visibility.isPaneVisible(plugin: "p"))

        _ = visibility.set(summary, visible: true)
        _ = visibility.set(body, visible: true)
        #expect(visibility.isPaneVisible(plugin: "p"))
        #expect(!visibility.isPaneVisible(plugin: "other"))

        _ = visibility.set(summary, visible: false)
        #expect(visibility.isPaneVisible(plugin: "p"))
        _ = visibility.set(body, visible: false)
        #expect(!visibility.isPaneVisible(plugin: "p"))
        #expect(visibility.isVisible(plugin: "p"))
    }
}
