import Foundation
import Testing

@testable import LeoKit

private func entry(
    _ id: String, name: String? = nil, symbol: String? = "checkmark.circle", text: String = "ok",
    color: LeoPluginAccessoryColor = .neutral, help: String? = nil
) throws -> LeoPluginAccessoryLayout.Entry {
    let accessory = LeoPluginNode.Accessory(sfSymbol: symbol, text: text, color: color, help: help)
    return .init(pluginID: id, pluginName: name ?? id, state: .tree(try LeoPluginSlotRoot(nodes: [.accessory(accessory)])))
}

@Suite struct LeoPluginAccessoryLayoutTests {
    @Test func aChipKeepsTheSlotItWasDrawnFrom() throws {
        let slot = LeoPluginSlotID.accessory(id: "pr", agent: LeoPluginAgentRef(machine: "localhost", name: "alpha"))
        let plain = try entry("a")
        let withSlot = LeoPluginAccessoryLayout.Entry(pluginID: plain.pluginID, pluginName: plain.pluginName, state: plain.state, slot: slot)

        let layout = LeoPluginAccessoryLayout(entries: [withSlot])

        #expect(layout.chips.map(\.slot) == [slot])
    }

    @Test func symbolOutsideTheAllowlistIsDroppedButTheTextStays() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", symbol: "applelogo", text: "hi")])
        #expect(layout.chips.count == 1)
        #expect(layout.chips[0].sfSymbol == nil)
        #expect(layout.chips[0].text == "hi")
    }

    @Test func allowlistedSymbolIsKept() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", symbol: "checkmark.circle.fill", text: "")])
        #expect(layout.chips.map(\.sfSymbol) == ["checkmark.circle.fill"])
    }

    @Test func aChipWithNeitherSymbolNorTextIsNotDrawn() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", symbol: "applelogo", text: "  ")])
        #expect(layout.chips.isEmpty)
        #expect(layout.overflow == nil)
    }

    @Test func textLongerThanEightCharactersIsClamped() throws {
        // A decoded accessory is capped at 8 already; the layout does not trust that.
        let accessory = LeoPluginNode.Accessory(sfSymbol: nil, text: "123456789abc")
        let root = try LeoPluginSlotRoot(nodes: [.accessory(accessory)])
        let layout = LeoPluginAccessoryLayout(entries: [.init(pluginID: "a", pluginName: "A", state: .tree(root))])
        #expect(layout.chips[0].text == "12345678")
    }

    @Test func textKeepsItsFirstLineOnly() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", symbol: nil, text: "ab\ncd")])
        #expect(layout.chips[0].text == "ab")
    }

    @Test func chipsAreOrderedByPluginIDWhateverTheInputOrder() throws {
        let layout = LeoPluginAccessoryLayout(
            entries: [try entry("studio.zeta"), try entry("studio.alpha")], maxVisible: 5)
        #expect(layout.chips.map(\.pluginID) == ["studio.alpha", "studio.zeta"])
    }

    @Test func onlyTwoShowThenTheRestCollapseToPlusN() throws {
        let layout = LeoPluginAccessoryLayout(
            entries: [try entry("a"), try entry("b"), try entry("c", text: "x"), try entry("d", text: "y")])
        #expect(layout.chips.map(\.pluginID) == ["a", "b"])
        #expect(layout.overflow?.count == 2)
        #expect(layout.overflow?.label == "+2")
    }

    @Test func aNarrowRowStepsDownToOneChipThenToPlusNAlone() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a"), try entry("b")])

        let one = layout.showing(1)
        #expect(one.chips.map(\.pluginID) == ["a"])
        #expect(one.overflow?.label == "+1")

        let none = layout.showing(0)
        #expect(none.chips.isEmpty)
        #expect(none.overflow?.label == "+2")
        #expect(none.overflow?.help == "a: ok\nb: ok")
        #expect(layout.totalCount == 2)
    }

    @Test func showingMoreThanTheCapStillCollapsesTheRest() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a"), try entry("b"), try entry("c")])
        #expect(layout.showing(5).chips.count == 2)
        #expect(layout.showing(5).overflow?.count == 1)
    }

    @Test func overflowTooltipNamesTheHiddenPlugins() throws {
        let layout = LeoPluginAccessoryLayout(
            entries: [try entry("a"), try entry("b"), try entry("c", name: "Gamma", text: "x", help: "three open")])
        #expect(layout.overflow?.help == "Gamma: three open")
    }

    @Test func noOverflowAtExactlyTwo() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a"), try entry("b")])
        #expect(layout.chips.count == 2)
        #expect(layout.overflow == nil)
    }

    @Test func tooltipIsAttributedToThePluginSoItCannotImpersonateLeo() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", name: "GitHub", text: "PR", help: "Rate limited")])
        #expect(layout.chips[0].help == "GitHub: Rate limited")
        let plain = LeoPluginAccessoryLayout(entries: [try entry("a", name: "GitHub", text: "PR")])
        #expect(plain.chips[0].help == "GitHub: PR")
    }

    @Test func slotsThatAreNotRenderedYieldNothing() {
        let states: [LeoPluginSlotState] = [.loading, .error("boom"), .disabled("off")]
        let layout = LeoPluginAccessoryLayout(entries: states.enumerated().map { .init(pluginID: "p\($0.offset)", pluginName: "P", state: $0.element) })
        #expect(layout.chips.isEmpty)
        #expect(layout.overflow == nil)
    }

    @Test func onlyTheFirstAccessoryOfARootCounts() throws {
        let first = LeoPluginNode.Accessory(sfSymbol: nil, text: "one")
        let second = LeoPluginNode.Accessory(sfSymbol: nil, text: "two")
        let root = try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil)), .accessory(first), .accessory(second)])
        let layout = LeoPluginAccessoryLayout(entries: [.init(pluginID: "a", pluginName: "A", state: .tree(root))])
        #expect(layout.chips.map(\.text) == ["one"])
    }

    @Test func colorsPassThroughAsSemanticValues() throws {
        let layout = LeoPluginAccessoryLayout(entries: [try entry("a", color: .failure)])
        #expect(layout.chips[0].color == .failure)
    }
}

@Suite struct LeoPluginSymbolAllowlistTests {
    @Test func commonStatusSymbolsAreAllowed() {
        for name in ["checkmark.circle", "xmark.circle.fill", "exclamationmark.triangle", "clock"] {
            #expect(LeoPluginSymbolAllowlist.isAllowed(name), "\(name)")
        }
    }

    @Test func brandAndArbitrarySymbolsAreNot() {
        for name in ["applelogo", "", "nonexistent.symbol", "lock.open.trianglebadge.exclamationmark"] {
            #expect(!LeoPluginSymbolAllowlist.isAllowed(name), "\(name)")
        }
    }
}
