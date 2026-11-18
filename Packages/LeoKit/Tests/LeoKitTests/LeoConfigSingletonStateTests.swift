import Foundation
import Testing

@testable import LeoKit

struct LeoConfigSingletonStateTests {
    private static func state(
        resource: String = "defaults", client: (any LeoConfigClient)? = nil, references: [String: [String]] = [:],
        transform: (@Sendable (LeoConfigResource) -> LeoConfigResource)? = nil
    ) async throws -> LeoConfigSingletonState {
        let client = try client ?? LeoConfigPaneFixtures.client()
        var state = LeoConfigSingletonState(resource: resource, references: references)
        state.beginLoading()
        state.loaded(await LeoConfigSingletonOps.load(resource: resource, client: client, references: references, transform: transform))
        return state
    }

    private static func success(
        revision: String, restart: LeoConfigRestartRequired = LeoConfigRestartRequired(), sentWith: String, draftWasCurrent: Bool,
        document: LeoConfigDocument
    ) -> LeoConfigSingletonWriteOutcome {
        LeoConfigSingletonWriteOutcome(
            result: .success(LeoConfigWriteResult(revision: revision, restartRequired: restart)), sentWith: sentWith,
            draftWasCurrent: draftWasCurrent, document: .success(document)
        )
    }

    @Test func setMarksDirtyAndCanSave() async throws {
        var state = try await Self.state()
        #expect(state.phase == .loaded)
        #expect(!state.isDirty)
        #expect(!state.canSave)

        state.set("model", .string("opus"))

        #expect(state.isDirty)
        #expect(state.canSave)
        #expect(state.draft?.patch == ["model": .string("opus")])
        state.revert("model")
        #expect(!state.isDirty)
    }

    @Test func canSaveFalseWhileBusyOrConflict() async throws {
        var state = try await Self.state()
        state.set("model", .string("opus"))

        _ = state.beginWrite()
        #expect(state.isBusy)
        #expect(!state.canSave)
        let refused = !state.beginWrite()
        #expect(refused)

        let sent = try #require(state.draft)
        _ = state.finishWrite(LeoConfigSingletonWriteOutcome(
            result: .failure(LeoConfigError.conflict(currentRevision: "r9")), sentWith: sent.revision, draftWasCurrent: true, document: nil
        ))
        state.failed(LeoConfigError.conflict(currentRevision: "r9"), sent: sent)
        #expect(!state.isBusy)
        #expect(state.conflict == LeoConfigSingletonState.Conflict(currentRevision: "r9"))
        #expect(!state.canSave)
    }

    @Test func failedConflictKeepsDraft() async throws {
        var state = try await Self.state()
        state.set("model", .string("opus"))
        let sent = try #require(state.draft)

        state.failed(LeoConfigError.conflict(currentRevision: "r9"), sent: sent)

        #expect(state.isDirty)
        #expect(state.draft?.value(at: "model") == .string("opus"))
        state.dismissConflict()
        #expect(state.conflict == nil)
        #expect(state.canSave)
    }

    @Test func failed422LandsOnField() async throws {
        var state = try await Self.state()
        state.set("model", .string("bogus"))
        let sent = try #require(state.draft)
        // An edit made while the write was out stays when the error lands.
        state.set("max_turns", .int(20))

        state.failed(LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]), sent: sent)

        #expect(state.draft?.errors(for: "model") == ["no such model"])
        #expect(state.draft?.value(at: "max_turns") == .int(20))
        #expect(!state.canSave)
        state.failed(LeoDaemonError.daemon(code: "internal", message: "disk full", matches: []), sent: sent)
        #expect(state.errorMessage == "disk full")
    }

    @Test func finishWriteRebasesOnlyWhenDraftWasCurrent() async throws {
        var state = try await Self.state()
        let opened = try #require(state.draft).revision
        state.set("model", .string("opus"))
        state.set("max_turns", .int(20))
        let fresh = LeoConfigDocument(revision: "r2", values: ["model": .string("opus"), "max_turns": .int(10)])

        var behind = state
        _ = behind.beginWrite()
        #expect(behind.isBusy)
        _ = behind.finishWrite(Self.success(revision: "r2", sentWith: "other", draftWasCurrent: false, document: fresh))
        #expect(behind.draft?.revision == opened)
        #expect(behind.draft?.patch == ["model": .string("opus"), "max_turns": .int(20)])

        _ = state.beginWrite()
        #expect(state.isBusy)
        let failure = state.finishWrite(Self.success(revision: "r2", sentWith: opened, draftWasCurrent: true, document: fresh))
        #expect(failure == nil)
        #expect(state.draft?.revision == "r2")
        #expect(state.draft?.patch == ["max_turns": .int(20)])
        #expect(!state.isBusy)
    }

    @Test func restartRequiredRaisesPrompt() async throws {
        var state = try await Self.state()
        state.set("model", .string("opus"))
        let fresh = LeoConfigDocument(revision: "r2", values: ["model": .string("opus")])
        let restart = LeoConfigRestartRequired(service: false, agents: true)

        _ = state.beginWrite()
        #expect(state.isBusy)
        _ = state.finishWrite(Self.success(revision: "r2", restart: restart, sentWith: "r1", draftWasCurrent: true, document: fresh))

        #expect(state.restartPrompt == restart)
        state.dismissRestartPrompt()
        #expect(state.restartPrompt == nil)
    }

    @Test func newReferencesRevalidateDraft() async throws {
        var state = try await Self.state(
            resource: "client", references: ["hosts": ["remote"]], transform: { $0.referencing("default_host", to: "hosts", emptyLabel: "None") }
        )
        state.set("default_host", .string("staging"))
        #expect(!state.canSave)

        state.setReferences(["hosts": ["remote", "staging"]])

        #expect(state.canSave)
        let control = state.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote", "staging"], emptyLabel: "None"))
    }
}
