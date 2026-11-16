import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Every way Settings opens lands on the matching sidebar item, in a real
/// window (so a split view misconfiguration fails here, at construction).
@MainActor struct LeoSettingsWindowEntryTests {
    private typealias Support = LeoMachineRegistryTestSupport

    private struct Rig {
        let controller: LeoSettingsWindowController
        let registry: LeoMachineRegistry
        let defaults: LeoInMemoryDefaults
        let dionysus: LeoHostConfiguration
    }

    private func rig(hosts: [String] = ["dionysus", "hestia"]) throws -> Rig {
        let defaults = LeoInMemoryDefaults()
        try Support.save(hosts.map { Support.host($0) }, to: defaults)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)
        let controller = LeoSettingsWindowController(
            registry: registry, clients: FakeMachineClients(), defaults: LeoInMemoryDefaults(), prompting: nil
        )
        return Rig(controller: controller, registry: registry, defaults: defaults, dionysus: Support.host("dionysus"))
    }

    @Test func settingsOpensTheThisMacOverviewFirst() throws {
        let rig = try rig()
        rig.controller.show(.settings)
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .machine(.local))
        #expect(rig.controller.target?.selectedHost == .local)
        #expect(rig.controller.target?.selectedTab == .overview)
        #expect(rig.controller.window?.title == "This Mac")
    }

    @Test func machinesWithNoHostOpensThisMacWhenNothingIsRemembered() throws {
        let rig = try rig()
        rig.controller.show(.machines(nil))
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .machine(.local))
    }

    @Test func editMachineOpensThatRemotesOverview() throws {
        let rig = try rig()
        rig.controller.show(.machines(.remote("dionysus")))
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .machine(.remote(rig.dionysus.id)))
        #expect(rig.controller.target?.selectedHost == .remote("dionysus"))
        #expect(rig.controller.target?.selectedTab == .overview)
        #expect(rig.controller.model?.selectedID == rig.dionysus.id)
        #expect(rig.controller.window?.title == "dionysus")
    }

    @Test func editAppearanceRulesOpensThatMachinesAppearancePane() throws {
        let rig = try rig()
        rig.controller.show(.appearance(.remote("dionysus")))
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .pane(.remote(rig.dionysus.id), .appearance))
        #expect(rig.controller.target?.selectedHost == .remote("dionysus"))
        #expect(rig.controller.target?.selectedTab == LeoAppearanceSettingsView.tab)
        #expect(rig.controller.window?.title == "Appearance")
        #expect(rig.controller.window?.subtitle == "dionysus")
    }

    @Test func anOpenWindowMovesToTheNewEntry() throws {
        let rig = try rig()
        rig.controller.show(.settings)
        rig.controller.show(.appearance(.remote("hestia")))
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .pane(.remote(Support.host("hestia").id), .appearance))
        #expect(rig.controller.target?.selectedHost == .remote("hestia"))
    }

    @Test func settingsOnAnOpenWindowLeavesItWhereItIs() throws {
        let rig = try rig()
        rig.controller.show(.appearance(.local))
        rig.controller.show(.settings)
        defer { rig.controller.window?.close() }

        #expect(rig.controller.sidebar?.selection == .pane(.local, .appearance))
    }

    @Test func reopeningRestoresTheLastItem() throws {
        let rig = try rig()
        rig.controller.show(.appearance(.remote("dionysus")))
        rig.controller.window?.close()
        #expect(rig.controller.sidebar == nil)

        rig.controller.show(.settings)
        defer { rig.controller.window?.close() }
        #expect(rig.controller.sidebar?.selection == .pane(.remote(rig.dionysus.id), .appearance))
        #expect(rig.controller.target?.selectedHost == .remote("dionysus"))
    }

    @Test func aRememberedMachineThatIsGoneOpensThisMac() throws {
        let rig = try rig()
        rig.controller.show(.machines(.remote("dionysus")))
        rig.controller.window?.close()
        try Support.save([Support.host("hestia")], to: rig.defaults)
        rig.registry.reload()

        rig.controller.show(.settings)
        defer { rig.controller.window?.close() }
        #expect(rig.controller.sidebar?.selection == .machine(.local))
        #expect(rig.controller.target?.selectedHost == .local)
    }

    @Test func generalAndPluginsAreRememberedToo() throws {
        let rig = try rig()
        rig.controller.show(.settings)
        rig.controller.sidebar?.select(.general)
        rig.controller.window?.close()

        rig.controller.show(.settings)
        defer { rig.controller.window?.close() }
        #expect(rig.controller.sidebar?.selection == .general)
        #expect(rig.controller.window?.title == "General")
    }
}
