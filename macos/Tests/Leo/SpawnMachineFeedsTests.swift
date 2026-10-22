import Combine
import Foundation
import Testing
@testable import Ghostty
@testable import LeoKit

/// The sheet's per-machine mapping onto the sidebar model and
/// `LeoAgentActions` (S5a review: it was untested inside the view).
@MainActor struct SpawnMachineFeedsTests {
    private static let work = LeoHostID.remote("work")

    private func fixture() -> (sidebar: LeoSidebarModel, actions: LeoAgentActions, feeds: SpawnMachineFeeds) {
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(), cli: .recordingForTests(templates: ["claude"]), model: sidebar,
            processRunner: LeoRecordingTemplateRunner(templates: ["claude"]), refresh: {})
        return (sidebar, actions, .live(sidebar: sidebar, actions: actions))
    }

    private func latest<T>(_ publisher: AnyPublisher<T, Never>) -> T? {
        var value: T?
        let cancellable = publisher.sink { value = $0 }
        cancellable.cancel()
        return value
    }

    @Test func aMachineWithNoListYetIsLoading() {
        let feeds = fixture().feeds
        #expect(latest(feeds.templateList(Self.work)) == .loading)
        #expect(latest(feeds.environmentCatalog(Self.work)) == .loading)
    }

    @Test func machinesAreTheSidebarsMachinesInOrderWithTheirStatuses() {
        let (sidebar, _, feeds) = fixture()
        sidebar.setMachines([.local, Self.work])
        sidebar.setMachineStatuses([.local: .connected, Self.work: .failed("timed out")])

        #expect(latest(feeds.machines) == [
            SpawnMachineOption(host: .local, status: .connected), SpawnMachineOption(host: Self.work, status: .failed("timed out"))
        ])
    }

    @Test func aMachineWithoutAStatusIsConnectingExceptThisMac() {
        let (sidebar, _, feeds) = fixture()
        sidebar.setMachines([.local, Self.work])

        #expect(latest(feeds.machines) == [
            SpawnMachineOption(host: .local, status: .connected), SpawnMachineOption(host: Self.work, status: .connecting)
        ])
    }

    @Test func beforeTheRuntimeNamesMachinesOnlyThisMacIsListed() {
        #expect(latest(fixture().feeds.machines) == [SpawnMachineOption(host: .local, status: .connected)])
    }

    @Test func theEnvironmentsGateReadsTheMachinesAdvertisedFeatures() {
        let (sidebar, _, feeds) = fixture()
        #expect(latest(feeds.environmentsSupported(Self.work)) == false)
        sidebar.receive(
            LeoSidebarSnapshot(rows: [], connectivity: .connected, generation: 1, listRefreshSucceeded: true, features: LeoDaemonFeatures(["agent_environments"]), featuresHost: Self.work),
            for: Self.work)
        #expect(latest(feeds.environmentsSupported(Self.work)) == true)
        #expect(latest(feeds.environmentsSupported(.local)) == false)
    }

    @Test func optionsSayWhyAMachineCannotBePicked() {
        #expect(SpawnMachineOption(host: .local, status: .connected).detail == nil)
        #expect(SpawnMachineOption(host: Self.work, status: .failed("timed out")).detail == "Unreachable · timed out")
        #expect(SpawnMachineOption(host: Self.work, status: .connecting).detail == "Connecting…")
        #expect(SpawnMachineOption(host: Self.work, status: .disabled).detail == "Disabled")
        #expect(SpawnMachineOption(host: .local, status: .connected).title == "This Mac")
        #expect(SpawnMachineOption(host: Self.work, status: .connected).title == "work")
    }
}

/// `leo.lastSpawnMachine` keeps `LeoHostID.displayName`'s spelling
/// ("localhost" for This Mac), as the S2 migration wrote it.
@MainActor struct SpawnMachineMemoryTests {
    @Test func rememberedMachinesRoundTrip() {
        let memory = SpawnMachineMemory(defaults: LeoInMemoryDefaults())
        #expect(memory.lastUsed == nil)
        memory.remember(.remote("work"))
        #expect(memory.lastUsed == .remote("work"))
        memory.remember(.local)
        #expect(memory.lastUsed == .local)
    }

    @Test func readsWhatTheMigrationWrote() {
        let defaults = LeoInMemoryDefaults()
        defaults.set("localhost", forKey: LeoMachineDefaultsMigration.lastSpawnMachineKey)
        #expect(SpawnMachineMemory(defaults: defaults).lastUsed == .local)
    }
}
