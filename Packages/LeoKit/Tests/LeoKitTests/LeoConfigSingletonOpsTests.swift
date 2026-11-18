import Foundation
import Testing

@testable import LeoKit

struct LeoConfigSingletonOpsTests {
    private static func updates(_ fake: LeoFakeConfigClient) async -> [LeoFakeConfigCall] {
        await fake.calls.filter { if case .update = $0 { true } else { false } }
    }

    private static func draft(_ fake: LeoFakeConfigClient, _ resource: String = "defaults") async throws -> LeoConfigDraft {
        LeoConfigDraft(document: try await fake.document(resource))
    }

    @Test func saveSendsOnlyChangedKeysWithResolvedRevision() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let revisions = LeoConfigRevisionTracker()
        var draft = try await Self.draft(fake)
        // Another pane of the app wrote since this form was read.
        let web = try await fake.document("web")
        let other = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: web.revision)
        revisions.recordWrite(from: web.revision, to: other.revision)
        draft.set("model", .string("opus"))

        let outcome = await LeoConfigSingletonOps.write(resource: "defaults", client: fake, revisions: revisions, sent: draft)

        #expect(try outcome.result.get().revision == (await fake.currentRevision))
        let sent = try #require(await Self.updates(fake).last)
        #expect(sent == .update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: other.revision))
    }

    @Test func writeRecordsSentWithThenRereads() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let revisions = LeoConfigRevisionTracker()
        var draft = try await Self.draft(fake)
        draft.set("model", .string("opus"))

        let outcome = await LeoConfigSingletonOps.write(resource: "defaults", client: fake, revisions: revisions, sent: draft)

        let result = try outcome.result.get()
        #expect(outcome.sentWith == draft.revision)
        #expect(outcome.draftWasCurrent)
        #expect(revisions.resolve(draft.revision) == result.revision)
        let reread = try #require(try outcome.document?.get())
        #expect(reread.revision == result.revision)
        #expect(reread.values["model"] == .string("opus"))
    }

    @Test func aRefusedWriteIsReturnedAndNothingIsRecorded() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        let revisions = LeoConfigRevisionTracker()
        var draft = try await Self.draft(fake)
        await fake.externalChange("defaults", values: ["max_turns": .int(3)])
        draft.set("model", .string("opus"))

        let outcome = await LeoConfigSingletonOps.write(resource: "defaults", client: fake, revisions: revisions, sent: draft)

        guard case .failure(LeoConfigError.conflict) = outcome.result else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(outcome.document == nil)
        #expect(revisions.resolve(draft.revision) == draft.revision)
    }

    @Test func overwriteReplaysOverFreshRead() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var stale = try await Self.draft(fake)
        stale.set("model", .string("opus"))
        await fake.externalChange("defaults", values: ["max_turns": .int(3)])
        let current = await fake.currentRevision

        let outcome = await LeoConfigSingletonOps.overwrite(
            stale: stale, resource: "defaults", client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .sent(let replayed, let write) = outcome else {
            Issue.record("Expected a write")
            return
        }
        #expect(replayed.revision == current)
        #expect(replayed.value(at: "max_turns") == .int(3))
        #expect(write.draftWasCurrent)
        let sent = try #require(await Self.updates(fake).last)
        #expect(sent == .update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: current))
        let stored = try await fake.document("defaults").values
        #expect(stored["model"] == .string("opus"))
        #expect(stored["max_turns"] == .int(3))
    }

    @Test func overwriteNothingToSend() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var stale = try await Self.draft(fake)
        stale.set("model", .string("opus"))
        await fake.externalChange("defaults", values: ["model": .string("opus")])

        let outcome = await LeoConfigSingletonOps.overwrite(
            stale: stale, resource: "defaults", client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .nothingToSend(let replayed) = outcome else {
            Issue.record("Expected nothing to send")
            return
        }
        #expect(!replayed.isDirty)
        #expect(await Self.updates(fake).isEmpty)
    }

    @Test func overwriteWhoseReadFailsSendsNothing() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        var stale = try await Self.draft(fake)
        stale.set("model", .string("opus"))
        await fake.failNextRead(with: LeoDaemonError.transport("tunnel down"))

        let outcome = await LeoConfigSingletonOps.overwrite(
            stale: stale, resource: "defaults", client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .readFailed = outcome else {
            Issue.record("Expected the read to fail")
            return
        }
        #expect(await Self.updates(fake).isEmpty)
    }

    @Test func clientLoadReadsHostNamesAsReferences() async throws {
        let fake = try LeoConfigPaneFixtures.client()

        let load = await LeoConfigSingletonOps.load(
            resource: "client", client: fake, references: [:],
            transform: { $0.referencing("default_host", to: "hosts", emptyLabel: "None") }
        )

        #expect(load.failure == nil)
        #expect(load.references == ["hosts": ["remote"]])
        #expect(load.schema?.resource("client")?.field("default_host")?.type == .reference)
        #expect(load.document?.values["default_host"] == .string("remote"))
        #expect(load.webDocument != nil)
    }

    @Test func loadKeepsNamesItIsGivenAndReadsNoOthers() async throws {
        let fake = try LeoConfigPaneFixtures.client()

        let load = await LeoConfigSingletonOps.load(
            resource: "client", client: fake, references: ["hosts": ["given"]],
            transform: { $0.referencing("default_host", to: "hosts", emptyLabel: "None") }
        )

        #expect(load.references == ["hosts": ["given"]])
        #expect(!(await fake.calls).contains(.collection("hosts")))
    }

    @Test func aFailedLoadSaysWhy() async throws {
        let fake = try LeoConfigPaneFixtures.client()
        await fake.failNextRead(with: LeoDaemonError.transport("tunnel down"))

        let load = await LeoConfigSingletonOps.load(resource: "defaults", client: fake, references: [:])

        #expect(load.failure != nil)
        #expect(load.document == nil)
    }
}
