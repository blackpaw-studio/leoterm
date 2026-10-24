import Foundation
import Testing

@testable import LeoKit

struct LeoConfigCollectionStateTests {
    private static func state(autoSelectsFirst: Bool = true) async throws -> LeoConfigCollectionState {
        try await LeoConfigPaneFixtures.loadedState(client: try LeoConfigPaneFixtures.client(), autoSelectsFirst: autoSelectsFirst)
    }

    private static func collection(revision: String, items: [LeoConfigItem]) -> LeoConfigCollection {
        LeoConfigCollection(revision: revision, items: items)
    }

    @Test func applyCarriesDraftOnlyForSameItem() async throws {
        var state = try await Self.state()
        state.set("model", .string("sonnet"))
        let kept = try #require(state.draft)
        let collection = Self.collection(revision: "r2", items: state.items)

        state.apply(collection, preferring: "coder", carrying: kept)
        #expect(state.draft?.isDirty == true)
        #expect(state.draft?.revision == "r2")

        state.apply(collection, preferring: "reviewer", carrying: kept)
        #expect(state.selection == "reviewer")
        #expect(state.draft?.document.name == "reviewer")
        #expect(state.draft?.isDirty == false)
    }

    @Test func applyWithoutRebasingKeepsDraftOnItsRevision() async throws {
        var state = try await Self.state()
        let opened = try #require(state.draft).revision
        state.set("model", .string("sonnet"))
        let kept = try #require(state.draft)
        let collection = Self.collection(revision: "r2", items: state.items)

        state.apply(collection, preferring: "coder", carrying: kept, rebasing: false)
        #expect(state.draft?.revision == opened)
        #expect(state.draft?.isDirty == true)
        #expect(state.revision == "r2")

        state.apply(collection, preferring: "coder", carrying: kept, rebasing: true)
        #expect(state.draft?.revision == "r2")
    }

    @Test func iOSModeDoesNotAutoSelect() async throws {
        let mac = try await Self.state()
        let phone = try await Self.state(autoSelectsFirst: false)

        #expect(mac.selection == "coder")
        #expect(phone.items.map(\.name) == ["coder", "reviewer"])
        #expect(phone.selection == nil)
        #expect(phone.draft == nil)
        #expect(phone.phase == .loaded)
    }

    @Test func selectWhileDirtyAsks() async throws {
        var state = try await Self.state()
        state.requestSelect("reviewer", extraUnsaved: false)
        #expect(state.selection == "reviewer")

        state.set("model", .string("sonnet"))
        state.requestSelect("coder", extraUnsaved: false)
        #expect(state.selection == "reviewer")
        #expect(state.confirmation == .discardChanges(thenSelect: "coder"))

        var clean = try await Self.state()
        clean.requestSelect("reviewer", extraUnsaved: true)
        #expect(clean.selection == "coder")
        #expect(clean.confirmation == .discardChanges(thenSelect: "reviewer"))
    }

    @Test func failedConflictKeepsDraft() async throws {
        var state = try await Self.state()
        state.set("model", .string("sonnet"))
        let sent = try #require(state.draft)

        state.failed(LeoConfigError.conflict(currentRevision: "r9"), sent: sent)

        #expect(state.conflict == LeoConfigCollectionState.Conflict(currentRevision: "r9"))
        #expect(state.draft?.isDirty == true)
        #expect(!state.canSave)
    }

    @Test func failed422LandsOnField() async throws {
        var state = try await Self.state()
        state.set("model", .string("sonnet"))
        let sent = try #require(state.draft)

        state.failed(LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "unknown model")]), sent: sent)

        #expect(state.draft?.errors(for: "model") == ["unknown model"])
        #expect(state.errorMessage == nil)
        #expect(!state.canSave)
    }

    @Test func restructureNeedsCleanDraft() async throws {
        var state = try await Self.state()
        #expect(state.canRestructure)
        #expect(state.allows(.rename))
        #expect(state.allows(.add))

        state.set("model", .string("sonnet"))
        #expect(!state.canRestructure)
        #expect(!state.allows(.delete))

        state.revertAll()
        #expect(state.hasUnsavedChanges(extra: false) == false)
        #expect(state.hasUnsavedChanges(extra: true))
        let started = state.beginWrite()
        #expect(started)
        #expect(!state.canRestructure)
    }

    @Test func theWebLinkFallsBackToThePairedOrigin() async throws {
        let client = try LeoConfigPaneFixtures.client()
        var state = LeoConfigCollectionState(resource: "templates", webOrigin: URL(string: "https://leo.example.com"))
        state.loaded(await LeoConfigCollectionOps.load(resource: "templates", client: client, references: [:]))

        // The golden web document is enabled and bound to loopback, so only the paired origin can reach it.
        #expect(state.webLink == URL(string: "https://leo.example.com/config/templates/coder"))
    }
}
