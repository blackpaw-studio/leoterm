import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoSettingsSidebarItemTests {
    private static let dionysus = LeoHostConfiguration(name: "dionysus", sshTarget: "evan@dionysus")
    private static let hestia = LeoHostConfiguration(name: "hestia", sshTarget: "evan@hestia")
    private static let saved = [dionysus, hestia]

    private func resolve(_ item: LeoSettingsSidebarItem, draft: [LeoHostConfiguration] = []) -> LeoSettingsSidebarItem.Resolution {
        LeoSettingsSidebarItem.resolve(item, configurations: Self.saved, draft: draft)
    }

    // MARK: resolve

    @Test func thisMacOverviewTargetsTheLocalMachineOverview() {
        let resolution = resolve(.machine(.local))
        #expect(resolution.host == .local)
        #expect(resolution.tab == .overview)
    }

    @Test func aRemotePaneTargetsThatRemoteAndTheMatchingTab() {
        let resolution = resolve(.pane(.remote(Self.dionysus.id), .tasks))
        #expect(resolution.host == .remote("dionysus"))
        #expect(resolution.tab == LeoTasksSettingsView.tab)
    }

    @Test func everyPaneMapsToItsOwnConfigTab() {
        let tabs = LeoSettingsMachinePane.allCases.map { resolve(.pane(.local, $0)).tab }
        #expect(Set(tabs).count == LeoSettingsMachinePane.allCases.count)
        #expect(tabs.allSatisfy { if case .config = $0 { true } else { false } })
    }

    @Test func aRemovedRemoteFallsBackToTheThisMacOverview() {
        let gone = UUID()
        #expect(resolve(.machine(.remote(gone))) == .init(item: .machine(.local), host: .local, tab: .overview))
        #expect(resolve(.pane(.remote(gone), .daemon)) == .init(item: .machine(.local), host: .local, tab: .overview))
    }

    @Test func appPagesCarryNoMachine() {
        #expect(resolve(.general) == .init(item: .general, host: nil, tab: .general))
        #expect(resolve(.plugins) == .init(item: .plugins, host: nil, tab: .plugins))
    }

    @Test func aRenamedRemoteResolvesToItsNewName() {
        let renamed = Self.dionysus.replacing(name: "dionysus-2")
        let resolution = LeoSettingsSidebarItem.resolve(
            .machine(.remote(Self.dionysus.id)), configurations: [renamed, Self.hestia]
        )
        #expect(resolution.host == .remote("dionysus-2"))
    }

    @Test func anUnsavedRemoteKeepsItsItemButHasNoHostYet() {
        let unsaved = LeoHostConfiguration(name: "new", sshTarget: "")
        let resolution = resolve(.machine(.remote(unsaved.id)), draft: [unsaved])
        #expect(resolution.item == .machine(.remote(unsaved.id)))
        #expect(resolution.host == nil)
        #expect(resolution.tab == .overview)
    }

    // MARK: panes enabled

    @Test func panesAreDisabledForADisabledFailedOrUnknownMachine() {
        let enabled = { (status: LeoMachineStatus?) in LeoSettingsSidebarItem.panesEnabled(status: status) }
        let disabled: LeoMachineStatus = .disabled
        let failed: LeoMachineStatus = .failed("no route")
        #expect(enabled(disabled) == false)
        #expect(enabled(failed) == false)
        #expect(enabled(nil) == false)
        #expect(enabled(LeoMachineStatus.connected) == true)
        #expect(enabled(LeoMachineStatus.connecting) == true)
    }

    // MARK: entries

    private func item(_ entry: LeoSettingsEntry, remembered: LeoSettingsSidebarItem? = nil) -> LeoSettingsSidebarItem {
        entry.item(remembered: remembered, configurations: Self.saved)
    }

    @Test func settingsOpensTheRememberedItemElseThisMac() {
        #expect(item(.settings) == .machine(.local))
        #expect(item(.settings, remembered: .general) == .general)
        let pane = LeoSettingsSidebarItem.pane(.remote(Self.hestia.id), .defaults)
        #expect(item(.settings, remembered: pane) == pane)
    }

    @Test func settingsFallsBackToThisMacWhenTheRememberedMachineIsGone() {
        #expect(item(.settings, remembered: .pane(.remote(UUID()), .tasks)) == .machine(.local))
    }

    @Test func machinesWithAHostOpensThatRemotesOverview() {
        #expect(item(.machines(.remote("hestia")), remembered: .general) == .machine(.remote(Self.hestia.id)))
        #expect(item(.machines(.local)) == .machine(.local))
    }

    @Test func machinesWithAnUnknownHostOpensThisMac() {
        #expect(item(.machines(.remote("gone"))) == .machine(.local))
    }

    @Test func machinesWithNoHostOpensTheRememberedMachinesOverview() {
        let remembered = LeoSettingsSidebarItem.pane(.remote(Self.dionysus.id), .tasks)
        #expect(item(.machines(nil), remembered: remembered) == .machine(.remote(Self.dionysus.id)))
    }

    @Test func machinesWithNoHostOpensThisMacWhenTheRememberedItemIsAppWideOrGone() {
        #expect(item(.machines(nil)) == .machine(.local))
        #expect(item(.machines(nil), remembered: .plugins) == .machine(.local))
        #expect(item(.machines(nil), remembered: .machine(.remote(UUID()))) == .machine(.local))
    }

    @Test func appearanceOpensThatMachinesAppearancePane() {
        #expect(item(.appearance(.remote("dionysus"))) == .pane(.remote(Self.dionysus.id), .appearance))
        #expect(item(.appearance(.local)) == .pane(.local, .appearance))
    }
}
