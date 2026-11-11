import Combine
import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginCommandSourceTests {
    private let open = LeoPluginCommandContribution(id: "open-pr", title: "Open Pull Request", sfSymbol: "arrow.triangle.pull")
    private let plain = LeoPluginCommandContribution(id: "sign-in", title: "Sign In")

    private let surface = FakePluginPaneHost()

    private func make() -> (LeoPluginManagerCommandSource, LeoPluginSlotHostFake) {
        let host = LeoPluginSlotHostFake(plugins: [
            LeoPluginTestPlugins.info(name: "GitHub", commands: [open, plain]),
            LeoPluginTestPlugins.info(id: "studio.test.off", name: "Off", enabled: false, commands: [plain]),
        ])
        return (LeoPluginManagerCommandSource(host: host, surface: surface), host)
    }

    private func list(_ title: String) throws -> LeoPluginNode {
        .list(.init(sections: [.init(items: [.init(id: "i", title: title)])]))
    }

    @Test func commandsOfEnabledPluginsAppearWithTitleSymbolAndPlugin() {
        let (source, _) = make()
        #expect(source.commands.map(\.title) == ["Open Pull Request", "Sign In"])
        #expect(source.commands.map(\.sfSymbol) == ["arrow.triangle.pull", nil])
        #expect(source.commands.map(\.pluginName) == ["GitHub", "GitHub"])
    }

    @Test func selectingACommandSendsItsCommandSlotToThePlugin() {
        let (source, host) = make()
        _ = source.select(source.commands[0])
        #expect(host.opened == [LeoPluginSlotKey(pluginID: "studio.test.demo", slot: .palette(commandID: "open-pr"))])
    }

    @Test func pushViewSwapsTheContentAndEscapePopsBackToTheRoot() throws {
        let (source, host) = make()
        let session = source.select(source.commands[0])
        let key = session.key
        let root = try LeoPluginSlotRoot(nodes: [try list("root")])
        host.slots.render(pluginID: key.pluginID, slot: key.slot, root: root)
        host.slots.push(try list("pushed"), onto: key)

        #expect(session.back() == .popped)
        #expect(surface.popped == [key])
    }

    @Test func escapeAtTheRootReturnsToTheCommandList() throws {
        let (source, host) = make()
        let session = source.select(source.commands[0])
        host.slots.render(pluginID: session.key.pluginID, slot: session.key.slot, root: try LeoPluginSlotRoot(nodes: [try list("root")]))

        #expect(session.back() == .atRoot)
        #expect(surface.popped.isEmpty)
    }

    @Test func aCommandThatFinishesWithoutRenderingClosesItsPage() {
        let (source, host) = make()
        let session = source.select(source.commands[1])
        var closed = 0
        session.onFinishedWithoutRender = { closed += 1 }

        host.finishWithoutRender(source.commands[0].slotKey)
        #expect(closed == 0)

        host.finishWithoutRender(source.commands[1].slotKey)
        #expect(closed == 1)
    }

    @Test func theSessionDrawsThroughTheSharedSurfaceForItsOwnSlot() {
        let (source, _) = make()
        let session = source.select(source.commands[0])
        #expect(session.surface === surface)
        #expect(session.key == source.commands[0].slotKey)
    }
}
