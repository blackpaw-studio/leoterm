import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoHostsSheetModelTests {
    @Test func draftIsIsolatedFromTheStoreUntilSave() {
        let defaults = defaults()
        let store = LeoHostStore(defaults: defaults)
        try? store.save([.init(name: "work", sshTarget: "evan@work")])
        let model = LeoHostsSheetModel(store: store)

        model.updateSelected { .init(id: $0.id, name: "renamed", sshTarget: $0.sshTarget) }
        model.addHost()

        #expect(store.load().map(\.name) == ["work"], "editing the draft must not touch the store before save()")
    }

    @Test func cancelDiscardsTheDraft() {
        let defaults = defaults()
        let store = LeoHostStore(defaults: defaults)
        try? store.save([.init(name: "work", sshTarget: "evan@work")])
        let model = LeoHostsSheetModel(store: store)

        model.updateSelected { .init(id: $0.id, name: "renamed", sshTarget: $0.sshTarget) }
        // Cancel = just stop using the model without calling save().

        #expect(store.load().map(\.name) == ["work"])
    }

    @Test func saveWritesThroughTheStoreAndReloadsSorted() {
        let defaults = defaults()
        let store = LeoHostStore(defaults: defaults)
        let model = LeoHostsSheetModel(store: store)

        model.addHost()
        model.updateSelected { .init(id: $0.id, name: "zeta", sshTarget: "evan@zeta") }
        model.addHost()
        model.updateSelected { .init(id: $0.id, name: "alpha", sshTarget: "evan@alpha") }

        let saved = model.save()

        #expect(saved)
        #expect(store.load().map(\.name) == ["alpha", "zeta"], "load() sorts case-insensitively by name")
        #expect(model.hosts.map(\.name) == ["alpha", "zeta"], "the model reloads from the store after save()")
    }

    @Test func invalidTargetBlocksSaveWithTheRightMessage() {
        let model = LeoHostsSheetModel(store: LeoHostStore(defaults: defaults()))
        model.addHost()
        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "") }

        #expect(!model.isValid)
        #expect(model.errors(for: model.hosts[0]).contains("SSH target is required"))
        #expect(!model.save())
    }

    @Test func duplicateNameBlocksSaveWithTheRightMessage() {
        let model = LeoHostsSheetModel(store: LeoHostStore(defaults: defaults()))
        model.addHost()
        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "evan@work-a") }
        model.addHost()
        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "evan@work-b") }

        #expect(!model.isValid)
        #expect(model.errors(for: model.hosts[1]).contains(#"A host named "work" already exists"#))
        #expect(!model.save())
    }

    /// `save()` always attempts the write (the Save button's `disabled`
    /// state is a separate, UI-level gate via `isValid`) and surfaces
    /// whatever the store's own validation rejects.
    @Test func storeSaveErrorIsSurfacedInline() {
        let model = LeoHostsSheetModel(store: LeoHostStore(defaults: defaults()))
        model.hosts = [LeoHostConfiguration(name: "work", sshTarget: "@-bad")]
        model.selectedID = model.hosts.first?.id

        let saved = model.save()

        #expect(!saved)
        #expect(model.saveError != nil)
    }

    private func defaults() -> UserDefaults {
        let suite = "LeoHostsSheetModelTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}
