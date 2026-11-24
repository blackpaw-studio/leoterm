import Testing

@testable import Ghostty

/// B-438: the sidebar's section order. Moves work on the sections that
/// show; sections that don't keep their saved slot.
struct LeoSidebarSectionOrderTests {
    private typealias Order = LeoSidebarSectionOrder
    private let agents = Order.agents
    private let terminals = Order.terminals
    private let pluginA = Order.pluginKey("a")
    private let pluginB = Order.pluginKey("b")
    private let pluginC = Order.pluginKey("c")

    @Test func withNothingSavedTheLiveOrderIsTheDefault() {
        #expect(Order.arrange(saved: [], live: [agents, terminals, pluginA]) == [agents, terminals, pluginA])
    }

    @Test func newlyInstalledPluginSectionAppearsAtTheBottom() {
        let arranged = Order.arrange(saved: [pluginA, agents, terminals], live: [agents, terminals, pluginA, pluginB])
        #expect(arranged == [pluginA, agents, terminals, pluginB])
    }

    @Test func removingAPluginKeepsTheOthersInOrder() {
        let arranged = Order.arrange(saved: [pluginB, agents, pluginA, terminals, pluginC], live: [agents, terminals, pluginA, pluginC])
        #expect(arranged == [agents, pluginA, terminals, pluginC])
    }

    @Test func aRepeatedSavedKeyListsOnce() {
        #expect(Order.arrange(saved: [terminals, agents, terminals], live: [agents, terminals]) == [terminals, agents])
    }

    @Test func moveUpSkipsHiddenSectionsAndKeepsTheirSlot() {
        // Terminals is saved second but hidden (no shells, or the filter).
        let moved = Order.moving(
            pluginB, .up, visible: [agents, pluginB], saved: [agents, terminals, pluginB], known: [agents, terminals, pluginB]
        )
        #expect(moved == [pluginB, terminals, agents])
    }

    @Test func aFirstMoveSavesEveryKnownSection() {
        // Plugin C is disabled: not shown, but known, so it keeps a slot.
        let moved = Order.moving(
            pluginA, .up, visible: [agents, terminals, pluginA], saved: [], known: [agents, terminals, pluginA, pluginC]
        )
        #expect(moved == [agents, pluginA, terminals, pluginC])
    }

    @Test func moveDownSwapsWithTheNextShownSection() {
        let moved = Order.moving(agents, .down, visible: [agents, terminals], saved: [], known: [agents, terminals])
        #expect(moved == [terminals, agents])
    }

    @Test func moveUpAndDownAreDisabledAtTheEnds() {
        let visible = [agents, terminals, pluginA]
        #expect(!Order.canMove(agents, .up, visible: visible))
        #expect(Order.canMove(agents, .down, visible: visible))
        #expect(Order.canMove(terminals, .up, visible: visible) && Order.canMove(terminals, .down, visible: visible))
        #expect(!Order.canMove(pluginA, .down, visible: visible))
        #expect(Order.moving(agents, .up, visible: visible, saved: [], known: visible) == nil)
        #expect(Order.moving(pluginA, .down, visible: visible, saved: [], known: visible) == nil)
    }

    @Test func onlyVisibleSectionCannotMove() {
        // The filter has text: only Agents shows.
        #expect(!Order.canMove(agents, .up, visible: [agents]))
        #expect(!Order.canMove(agents, .down, visible: [agents]))
        #expect(Order.moving(agents, .down, visible: [agents], saved: [], known: [agents, terminals]) == nil)
    }

    @Test func aSectionThatIsNotShownCannotMove() {
        #expect(!Order.canMove(pluginC, .up, visible: [agents, terminals]))
        #expect(Order.moving(pluginC, .up, visible: [agents, terminals], saved: [], known: [agents, terminals, pluginC]) == nil)
    }

    @Test func droppingOnAHeaderTakesItsSlot() {
        let visible = [agents, terminals, pluginA, pluginB]
        #expect(
            Order.moving(agents, onto: pluginA, visible: visible, saved: [], known: visible) == [terminals, pluginA, agents, pluginB],
            "dropped on a header below, it lands after it"
        )
        #expect(
            Order.moving(pluginB, onto: terminals, visible: visible, saved: [], known: visible) == [agents, pluginB, terminals, pluginA],
            "dropped on a header above, it lands before it"
        )
        #expect(Order.moving(terminals, onto: terminals, visible: visible, saved: [], known: visible) == nil)
    }
}
