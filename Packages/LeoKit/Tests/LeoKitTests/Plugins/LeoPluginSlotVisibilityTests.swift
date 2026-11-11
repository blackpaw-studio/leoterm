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
}
