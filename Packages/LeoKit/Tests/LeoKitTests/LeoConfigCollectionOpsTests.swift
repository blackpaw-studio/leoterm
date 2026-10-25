import Foundation
import Testing

@testable import LeoKit

struct LeoConfigCollectionOpsTests {
    private static func update(
        _ fake: LeoFakeConfigClient, _ name: String, _ patch: [String: LeoConfigValue]
    ) -> @Sendable (String) async throws -> LeoConfigWriteResult {
        { ifMatch in try await fake.update("templates", name: name, patch: patch, ifMatch: ifMatch) }
    }

    @Test func retryOnceThenRecordsSentWith() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let revisions = LeoConfigRevisionTracker()
        let opened = await fake.currentRevision
        await fake.externalChange("templates", name: "reviewer", values: ["model": .string("haiku")])
        let current = await fake.currentRevision

        let outcome = await LeoConfigCollectionOps.write(
            resource: "templates", client: fake, revisions: revisions, ifMatch: opened, retryingConflict: true,
            operation: Self.update(fake, "coder", ["model": .string("sonnet")])
        )

        #expect(outcome.sentWith == current)
        let result = try outcome.result.get()
        #expect(revisions.resolve(current) == result.revision)
        #expect(revisions.resolve(opened) == opened)
        #expect(try outcome.collection?.get().revision == result.revision)
        let updates = await fake.calls.filter { if case .update = $0 { true } else { false } }
        #expect(updates.count == 2)
    }

    @Test func aConflictWithoutRetryingIsReturnedNotThrown() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let opened = await fake.currentRevision
        await fake.externalChange("templates", name: "reviewer", values: ["model": .string("haiku")])

        let outcome = await LeoConfigCollectionOps.write(
            resource: "templates", client: fake, revisions: LeoConfigRevisionTracker(), ifMatch: opened,
            operation: Self.update(fake, "coder", ["model": .string("sonnet")])
        )

        guard case .failure(LeoConfigError.conflict) = outcome.result else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(outcome.collection == nil)
    }

    @Test func draftNotCurrentAfterRetry() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let revisions = LeoConfigRevisionTracker()
        let opened = await fake.currentRevision
        await fake.externalChange("templates", name: "reviewer", values: ["model": .string("haiku")])

        let retried = await LeoConfigCollectionOps.write(
            resource: "templates", client: fake, revisions: revisions, ifMatch: opened, retryingConflict: true, draftRevision: opened,
            operation: Self.update(fake, "coder", ["model": .string("sonnet")])
        )
        #expect(!retried.draftWasCurrent)

        let fresh = await LeoConfigCollectionOps.write(
            resource: "templates", client: fake, revisions: revisions, ifMatch: try retried.result.get().revision, draftRevision: try retried.result.get().revision,
            operation: { ifMatch in try await fake.update("templates", name: "coder", patch: ["model": .string("sonnet")], ifMatch: ifMatch) }
        )
        #expect(fresh.draftWasCurrent)
    }

    @Test func overwriteReplaysOverFreshRead() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var state = try await LeoConfigPaneFixtures.loadedState(client: fake)
        state.set("model", .string("sonnet"))
        let stale = try #require(state.draft)
        await fake.externalChange("templates", name: "coder", values: ["max_turns": .int(7)])

        let outcome = await LeoConfigCollectionOps.overwrite(
            stale: stale, resource: "templates", name: "coder", client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .sent(let replayed, let write) = outcome else {
            Issue.record("Expected a write")
            return
        }
        #expect(replayed.patch == ["model": .string("sonnet")])
        let item = try await fake.item("templates", name: "coder")
        #expect(item.values["model"] == .string("sonnet"))
        #expect(item.values["max_turns"] == .int(7))
        #expect(try write.result.get().revision == item.revision)
    }

    @Test func overwriteNothingToSend() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var state = try await LeoConfigPaneFixtures.loadedState(client: fake)
        state.set("model", .string("sonnet"))
        let stale = try #require(state.draft)
        await fake.externalChange("templates", name: "coder", values: ["model": .string("sonnet")])

        let outcome = await LeoConfigCollectionOps.overwrite(
            stale: stale, resource: "templates", name: "coder", client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .nothingToSend(let replayed, let collection) = outcome else {
            Issue.record("Expected nothing to send")
            return
        }
        #expect(!replayed.isDirty)
        #expect(try collection.get().items.map(\.name).contains("coder"))
        let updates = await fake.calls.filter { if case .update = $0 { true } else { false } }
        #expect(updates.isEmpty)
    }

    @Test func restartRequiredSurfaces() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var state = try await LeoConfigPaneFixtures.loadedState(client: fake)
        state.set("model", .string("sonnet"))
        let sent = try #require(state.draft)
        let started = state.beginWrite()
        #expect(started)

        let outcome = await LeoConfigCollectionOps.write(
            resource: "templates", client: fake, revisions: LeoConfigRevisionTracker(), ifMatch: sent.revision, draftRevision: sent.revision,
            operation: Self.update(fake, "coder", sent.patch)
        )
        let failure = state.finishWrite(outcome, preferring: "coder")

        #expect(failure == nil)
        #expect(state.restartPrompt?.agents == true)
        #expect(!state.isBusy)
        #expect(state.draft?.isDirty == false)
    }

    @Test func loadReadsSchemaWebReferencesAndCollection() async throws {
        let fake = try LeoConfigPaneFixtures.client()

        let load = await LeoConfigCollectionOps.load(resource: "tasks", client: fake, references: [:])

        #expect(load.failure == nil)
        #expect(load.schema?.resource("tasks") != nil)
        #expect(load.webDocument != nil)
        #expect(load.references["templates"]?.contains("coder") == true)
        #expect(load.collection?.items.isEmpty == false)
    }
}
