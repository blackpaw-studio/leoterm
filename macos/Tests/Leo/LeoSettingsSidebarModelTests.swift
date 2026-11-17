import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoSettingsSidebarModelTests {
    static let dionysus = LeoHostConfiguration(name: "dionysus", sshTarget: "evan@dionysus")
    static let hestia = LeoHostConfiguration(name: "hestia", sshTarget: "evan@hestia", isEnabled: false)

    private final class Pane: LeoSettingsPane {
        var hasUnsavedChanges: Bool
        init(dirty: Bool) { hasUnsavedChanges = dirty }
        func discardChanges() { hasUnsavedChanges = false }
        func reload(using client: any LeoConfigClient) async {}
    }

    struct Harness {
        let sidebar: LeoSettingsSidebarModel
        let model: LeoMachinesSettingsModel
        let target: LeoSettingsTargetModel
        let store: LeoHostStore
        let machinesChanged: PassthroughSubject<Void, Never>
    }

    static func harness(initial: LeoSettingsSidebarItem = .machine(.local)) throws -> Harness {
        let store = LeoHostStore(defaults: LeoInMemoryDefaults())
        try store.save([dionysus, hestia])
        let model = LeoMachinesSettingsModel(store: store, tester: IdleTester())
        let target = LeoSettingsTargetModel(
            clients: FakeMachineClients(), machines: { [.local] + store.load().map { .remote($0.name) } }, status: { _ in nil },
            statuses: Empty().eraseToAnyPublisher(), reconnect: { _ in }, initialHost: nil
        )
        let changed = PassthroughSubject<Void, Never>()
        let sidebar = LeoSettingsSidebarModel(
            model: model, target: target, status: { _ in .connected }, configurations: { store.load() },
            machinesChanged: changed.eraseToAnyPublisher(), initial: initial
        )
        return Harness(sidebar: sidebar, model: model, target: target, store: store, machinesChanged: changed)
    }

    // MARK: rows

    @Test func rowsAreThisMacThenTheDraftsMachinesWithOffMarked() throws {
        let harness = try Self.harness()
        let rows = harness.sidebar.rows

        #expect(rows.map(\.name) == ["This Mac", "dionysus", "hestia"])
        #expect(rows.map(\.isOff) == [false, false, true])
        #expect(rows[0].accessibilityLabel == "This Mac, Connected")
        #expect(rows[2].accessibilityLabel == "hestia, Off")
        #expect(rows[2].panesEnabled == false)
    }

    // MARK: expansion

    @Test func theInitialMachineStartsExpanded() throws {
        let harness = try Self.harness()
        #expect(harness.sidebar.expanded == [.local])
    }

    @Test func selectingAnotherMachineCollapsesThePreviousAndExpandsTheNew() throws {
        let harness = try Self.harness()
        let dionysus = LeoSettingsMachineRef.remote(Self.dionysus.id)
        harness.sidebar.select(.machine(dionysus))

        #expect(harness.sidebar.selection == .machine(dionysus))
        #expect(harness.sidebar.expanded == [dionysus])
        #expect(harness.target.selectedHost == .remote("dionysus"))
    }

    @Test func selectingAPaneOfTheSameMachineKeepsItExpanded() throws {
        let harness = try Self.harness()
        harness.sidebar.select(.pane(.local, .tasks))

        #expect(harness.sidebar.expanded == [.local])
        #expect(harness.target.selectedTab == LeoTasksSettingsView.tab)
    }

    @Test func theChevronTogglesWithoutSelecting() throws {
        let harness = try Self.harness()
        let dionysus = LeoSettingsMachineRef.remote(Self.dionysus.id)
        harness.sidebar.toggleDisclosure(dionysus)

        #expect(harness.sidebar.isExpanded(dionysus))
        #expect(harness.sidebar.selection == .machine(.local))
        #expect(harness.target.selectedHost == .local)

        harness.sidebar.toggleDisclosure(dionysus)
        #expect(!harness.sidebar.isExpanded(dionysus))
    }

    @Test func anAppPageSelectionLeavesTheMachinesAsTheyWere() throws {
        let harness = try Self.harness()
        harness.sidebar.select(.general)

        #expect(harness.sidebar.selection == .general)
        #expect(harness.sidebar.expanded == [.local])
        #expect(harness.target.selectedTab == .general)
    }

    // MARK: pending changes

    @Test func aRefusedSelectionKeepsTheOldRowUntilConfirmed() throws {
        let harness = try Self.harness()
        let pane = Pane(dirty: true)
        harness.target.register(pane, for: .config("templates"))
        let dionysus = LeoSettingsMachineRef.remote(Self.dionysus.id)

        harness.sidebar.select(.pane(dionysus, .tasks))
        #expect(harness.sidebar.selection == .machine(.local))
        let pending = try #require(harness.sidebar.pendingSelection)
        #expect(pending.item == .pane(dionysus, .tasks))

        harness.sidebar.confirm(pending)
        #expect(harness.sidebar.selection == .pane(dionysus, .tasks))
        #expect(harness.sidebar.expanded == [dionysus])
        #expect(harness.target.selectedHost == .remote("dionysus"))
    }

    @Test func cancellingARefusedSelectionKeepsTheOldRow() throws {
        let harness = try Self.harness()
        let pane = Pane(dirty: true)
        harness.target.register(pane, for: .config("templates"))
        harness.sidebar.select(.machine(.remote(Self.dionysus.id)))
        harness.sidebar.cancelPending()

        #expect(harness.sidebar.selection == .machine(.local))
        #expect(harness.target.pendingChange == nil)
        #expect(pane.hasUnsavedChanges)
        #expect(harness.sidebar.pendingSelection == nil)
    }

    // MARK: removal, rename, add

    @Test func removingTheSelectedMachineFallsBackToThisMac() throws {
        let harness = try Self.harness()
        let dionysus = LeoSettingsMachineRef.remote(Self.dionysus.id)
        harness.sidebar.select(.pane(dionysus, .defaults))
        harness.model.requestRemoval(of: Self.dionysus.id)
        #expect(harness.model.confirmRemoval(Self.dionysus.id))

        #expect(harness.sidebar.selection == .machine(.local))
        #expect(harness.target.selectedHost == .local)
        #expect(harness.target.selectedTab == .overview)
        #expect(harness.sidebar.rows.map(\.name) == ["This Mac", "hestia"])
    }

    @Test func renamingTheSelectedMachineKeepsTheSelectionOnIt() throws {
        let harness = try Self.harness()
        let dionysus = LeoSettingsMachineRef.remote(Self.dionysus.id)
        harness.sidebar.select(.pane(dionysus, .tasks))
        harness.model.updateSelected { $0.replacing(name: "dionysus-2") }
        #expect(harness.model.save())
        harness.machinesChanged.send()

        #expect(harness.sidebar.selection == .pane(dionysus, .tasks))
        #expect(harness.target.selectedHost == .remote("dionysus-2"))
    }

    @Test func addingAMachineSelectsItsRow() throws {
        let harness = try Self.harness()
        harness.sidebar.addMachine()

        let added = try #require(harness.model.hosts.last)
        #expect(harness.sidebar.rows.last?.ref == .remote(added.id))
        #expect(harness.sidebar.selection == .machine(.remote(added.id)))
        #expect(harness.sidebar.expanded == [.remote(added.id)])
        // Nothing to connect to yet: the target stays where it was.
        #expect(harness.target.selectedHost == .local)
        #expect(harness.target.selectedTab == .overview)
    }
}
