import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoRemoteOverviewTests {
    private static let host = LeoHostConfiguration(name: "dionysus", sshTarget: "evan@dionysus")

    private func overview(
        _ host: LeoHostConfiguration = LeoRemoteOverviewTests.host, status: LeoMachineStatus? = .connected, isTarget: Bool = true,
        version: String? = "0.49.1"
    ) -> LeoRemoteOverview {
        LeoRemoteOverview(host: host, status: status, isTarget: isTarget, daemonVersion: version)
    }

    // MARK: presentation

    @Test func theVersionIsHiddenWhenTheTargetIsAnotherMachine() {
        #expect(overview(isTarget: true).version == "0.49.1")
        #expect(overview(isTarget: false).version == nil)
        #expect(overview(isTarget: true, version: nil).version == nil)
    }

    @Test func aDisabledMachineSaysOffAndShowsTheOffBadge() {
        let off = overview(Self.host.replacing(isEnabled: false), status: .connected)
        #expect(off.reason == "Off")
        #expect(off.status == .disabled)
        #expect(off.version == nil)
    }

    @Test func aFailedMachineShowsTheConnectionError() {
        #expect(overview(status: .failed("ssh: connection refused")).reason == "ssh: connection refused")
        #expect(overview(status: .connected).reason == nil)
        #expect(overview(status: .connecting).reason == nil)
    }

    @Test func theHeaderNamesTheMachineAndItsSSHTarget() {
        #expect(overview().name == "dionysus")
        #expect(overview().subtitle == "Remote over SSH · evan@dionysus")
        let blank = overview(LeoHostConfiguration(name: "", sshTarget: ""))
        #expect(blank.name == "Untitled")
        #expect(blank.subtitle == "Remote over SSH")
    }

    // MARK: Remove Machine…

    private func model(_ hosts: [LeoHostConfiguration] = [LeoRemoteOverviewTests.host]) throws -> (LeoMachinesSettingsModel, LeoHostStore) {
        let store = LeoHostStore(defaults: LeoInMemoryDefaults())
        try store.save(hosts)
        return (LeoMachinesSettingsModel(store: store, tester: IdleTester()), store)
    }

    @Test func removeAsksFirstAndChangesNothingYet() throws {
        let (model, store) = try model()
        model.requestRemoval(of: Self.host.id)

        #expect(model.pendingRemoval == Self.host.id)
        #expect(model.hosts.count == 1)
        #expect(store.load().count == 1)
    }

    @Test func cancellingTheQuestionKeepsTheMachine() throws {
        let (model, _) = try model()
        model.requestRemoval(of: Self.host.id)
        model.cancelRemoval()

        #expect(model.pendingRemoval == nil)
        #expect(model.hosts.count == 1)
        #expect(!model.confirmRemoval(), "a cancelled question can't be confirmed")
    }

    @Test func confirmingRemovesTheMachineAndSavesAtOnce() throws {
        let other = LeoHostConfiguration(name: "hestia", sshTarget: "evan@hestia")
        let (model, store) = try model([Self.host, other])
        model.requestRemoval(of: Self.host.id)

        #expect(model.confirmRemoval())
        #expect(model.hosts.map(\.name) == ["hestia"])
        #expect(store.load().map(\.name) == ["hestia"])
        #expect(model.pendingRemoval == nil)
        #expect(!model.isDirty)
    }

    @Test func removalIsRefusedWhenAnotherMachinesEditsCannotBeSaved() throws {
        let other = LeoHostConfiguration(name: "hestia", sshTarget: "evan@hestia")
        let (model, store) = try model([Self.host, other])
        model.selectedID = other.id
        model.updateSelected { $0.replacing(sshTarget: "") }
        model.requestRemoval(of: Self.host.id)

        #expect(!model.confirmRemoval())
        #expect(model.hosts.map(\.name) == ["dionysus", "hestia"], "the machine stays in the draft, in place")
        #expect(store.load().map(\.name) == ["dionysus", "hestia"])
        #expect(model.saveError != nil)
    }
}
