import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginCommandSourceTests {
    private let open = LeoPluginCommandContribution(id: "open-pr", title: "Open Pull Request", sfSymbol: "arrow.triangle.pull")
    private let plain = LeoPluginCommandContribution(id: "sign-in", title: "Sign In")

    private func make() -> (LeoPluginManagerCommandSource, LeoPluginSlotHostFake) {
        let host = LeoPluginSlotHostFake(plugins: [
            LeoPluginTestPlugins.info(name: "GitHub", commands: [open, plain]),
            LeoPluginTestPlugins.info(id: "studio.test.off", name: "Off", enabled: false, commands: [plain]),
        ])
        return (LeoPluginManagerCommandSource(host: host), host)
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

    @Test func theSessionShowsLoadingUntilThePluginRendersThenItsTree() throws {
        let (source, host) = make()
        let session = source.select(source.commands[0])
        #expect(session.nodes == [.loading(.init(message: nil))])
        let root = try LeoPluginSlotRoot(nodes: [try list("PR #1")])
        host.slots.render(pluginID: "studio.test.demo", slot: .palette(commandID: "open-pr"), root: root)
        #expect(session.nodes == root.nodes)
    }

    @Test func pushViewSwapsTheContentAndEscapePopsBackToTheRoot() throws {
        let (source, host) = make()
        let session = source.select(source.commands[0])
        let key = LeoPluginSlotKey(pluginID: "studio.test.demo", slot: .palette(commandID: "open-pr"))
        let root = try LeoPluginSlotRoot(nodes: [try list("root")])
        host.slots.render(pluginID: key.pluginID, slot: key.slot, root: root)
        host.slots.push(try list("pushed"), onto: key)
        #expect(session.nodes == [try list("pushed")])
        #expect(session.back() == .popped)
        #expect(session.nodes == root.nodes)
        #expect(session.back() == .atRoot)
    }

    @Test func aFailedSlotShowsTheErrorWithARetryThatReSendsTheCommand() {
        let (source, host) = make()
        let session = source.select(source.commands[0])
        host.slots.fail(pluginID: "studio.test.demo", slot: .palette(commandID: "open-pr"), message: "offline")
        guard case .error(let error) = session.nodes.first else {
            Issue.record("expected an error node")
            return
        }
        #expect(error.message == "offline")
        session.perform(error.retry, gesture: nil)
        #expect(host.retried == [LeoPluginSlotKey(pluginID: "studio.test.demo", slot: .palette(commandID: "open-pr"))])
        #expect(host.performed.isEmpty)
    }

    @Test func actionsInThePageGoToTheManagerWithTheCommandSlot() {
        let (source, host) = make()
        let session = source.select(source.commands[1])
        session.perform(.copy("x"), gesture: nil)
        #expect(host.performed.count == 1)
        #expect(host.performed[0].slot == .palette(commandID: "sign-in"))
    }
}
