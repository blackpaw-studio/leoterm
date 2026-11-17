import Testing

@testable import Ghostty
@testable import LeoKit

/// Remove Machine… saves the removal alone: nothing else in the draft is
/// written, and nothing in the window changes until that save has succeeded.
@MainActor
struct LeoMachineRemovalSaveTests {
    private static let alpha = LeoHostConfiguration(name: "alpha", sshTarget: "evan@alpha")
    private static let beta = LeoHostConfiguration(name: "beta", sshTarget: "evan@beta")

    private func model() throws -> (LeoMachinesSettingsModel, LeoHostStore) {
        let store = LeoHostStore(defaults: LeoInMemoryDefaults())
        try store.save([Self.alpha, Self.beta])
        return (LeoMachinesSettingsModel(store: store, tester: IdleTester()), store)
    }

    @Test func aFailedRemovalKeepsTheMachineSelectedAndShowsTheError() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let dionysus = LeoSettingsSidebarModelTests.dionysus
        harness.sidebar.select(.machine(.remote(dionysus.id)))
        // Another window saved first, so this window's save is refused.
        try harness.store.save(harness.store.load() + [LeoHostConfiguration(name: "extra", sshTarget: "evan@extra")])
        harness.model.requestRemoval(of: dionysus.id)

        #expect(!harness.model.confirmRemoval(dionysus.id))
        #expect(harness.sidebar.selection == .machine(.remote(dionysus.id)))
        #expect(harness.model.hosts.contains { $0.id == dionysus.id })
        #expect(harness.model.saveError != nil)
        #expect(harness.target.selectedHost == .remote("dionysus"))
    }

    @Test func anotherMachinesUnsavedEditSurvivesARemovalUnwritten() throws {
        let (model, store) = try model()
        model.selectedID = Self.beta.id
        model.updateSelected { $0.replacing(sshTarget: "evan@beta2") }
        model.requestRemoval(of: Self.alpha.id)

        #expect(model.confirmRemoval(Self.alpha.id))
        #expect(store.load().map(\.sshTarget) == ["evan@beta"], "only the removal is written")
        #expect(model.hosts.map(\.sshTarget) == ["evan@beta2"], "the edit stays in the draft")
        #expect(model.isDirty)

        model.revert()
        #expect(model.hosts.map(\.sshTarget) == ["evan@beta"])
    }

    @Test func removalSucceedsWhileAnotherMachinesEditsAreInvalid() throws {
        let (model, store) = try model()
        model.selectedID = Self.beta.id
        model.updateSelected { $0.replacing(sshTarget: "") }
        model.requestRemoval(of: Self.alpha.id)

        #expect(model.confirmRemoval(Self.alpha.id))
        #expect(store.load().map(\.name) == ["beta"])
        #expect(model.hosts.map(\.sshTarget) == [""], "the invalid edit stays pending")
        #expect(!model.isValid)
    }

    @Test func removingAnUnsavedMachineWritesNothing() throws {
        let (model, store) = try model()
        model.addHost()
        let added = try #require(model.hosts.last)
        model.requestRemoval(of: added.id)

        #expect(model.confirmRemoval(added.id))
        #expect(model.hosts.map(\.name) == ["alpha", "beta"])
        #expect(store.load().map(\.name) == ["alpha", "beta"])
        #expect(!model.isDirty)
    }
}
