import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationOpsTests {
    private static func fake(_ document: LeoDelegationDocument = LeoDelegationMatrixTests.document()) throws -> LeoFakeConfigClient {
        LeoFakeConfigClient(schema: try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema"), delegation: document)
    }

    /// A pane state holding what `fake` serves right now.
    private static func state(_ fake: LeoFakeConfigClient) async -> LeoDelegationPaneState {
        var state = LeoDelegationPaneState()
        state.beginLoading()
        state.loaded(await LeoDelegationOps.load(client: fake))
        return state
    }

    private static func writes(_ fake: LeoFakeConfigClient) async -> [(write: LeoFakeDelegationWrite, ifMatch: String)] {
        await fake.calls.compactMap { call in
            if case .delegationWrite(let write, let ifMatch) = call { (write, ifMatch) } else { nil }
        }
    }

    @Test func enabledRetriesOnceAndReportsSentWith() async throws {
        let fake = try Self.fake()
        let state = await Self.state(fake)
        let opened = try #require(state.document)
        await fake.externalDelegationChange(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder"))
        let current = await fake.currentRevision
        let revisions = LeoConfigRevisionTracker()

        let outcome = await LeoDelegationOps.write(
            .enabled(false), edits: state.edits, document: opened, client: fake, revisions: revisions, retryingConflict: true
        )

        #expect(outcome.sentWith == current)
        guard case .sent(let result, _, let readBack) = outcome.reply else {
            Issue.record("Expected the write to land")
            return
        }
        #expect(readBack?.enabled == false)
        #expect(revisions.resolve(current) == result.revision)
        #expect(revisions.resolve(opened.revision) == opened.revision)
        #expect(await Self.writes(fake).map(\.ifMatch) == [opened.revision, current])
    }

    @Test func aConflictWithoutRetryingIsReturned() async throws {
        let fake = try Self.fake()
        let state = await Self.state(fake)
        await fake.externalDelegationChange(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder"))

        let outcome = await LeoDelegationOps.write(
            .activate("deep"), edits: state.edits, document: try #require(state.document), client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .failed(LeoConfigError.conflict) = outcome.reply else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(await Self.writes(fake).count == 1)
    }

    @Test func overwriteSendsAgainstFreshRevision() async throws {
        let fake = try Self.fake()
        var state = await Self.state(fake)
        state.beginCellEdit(profile: "deep", role: "qa")
        state.setCellEffort("low")
        await fake.externalDelegationChange(
            profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "opus", effort: "high")
        )
        let current = await fake.currentRevision

        let outcome = await LeoDelegationOps.write(
            .cell, edits: state.edits, document: try #require(state.document), client: fake, revisions: LeoConfigRevisionTracker(),
            overwriting: true
        )

        #expect(outcome.fresh?.revision == current)
        let sent = try #require(await Self.writes(fake).last)
        #expect(sent.ifMatch == current)
        #expect(sent.write == .cell(profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "opus", effort: "low")))
    }

    @Test func cellSendsMergedTarget() async throws {
        let fake = try Self.fake()
        var state = await Self.state(fake)
        let opened = await fake.currentRevision
        state.beginCellEdit(profile: "deep", role: "qa")
        state.setCellEffort("low")
        // The pane read a newer copy (a reload) whose cell has another model.
        let base = LeoDelegationMatrixTests.document()
        let newer = LeoDelegationDocument(
            revision: opened, activeProfile: base.activeProfile, templates: base.templates, roles: base.roles,
            profiles: [
                LeoDelegationProfile(name: "deep", roles: [
                    "coder": LeoDelegationCell(template: "coder"), "qa": LeoDelegationCell(template: "reviewer", model: "opus-x", effort: "high"),
                ]),
                LeoDelegationProfile(name: "fast", active: true, roles: ["coder": LeoDelegationCell(template: "reviewer")]),
            ]
        )

        _ = await LeoDelegationOps.write(.cell, edits: state.edits, document: newer, client: fake, revisions: LeoConfigRevisionTracker())

        let sent = try #require(await Self.writes(fake).last)
        #expect(sent.ifMatch == opened)
        #expect(sent.write == .cell(profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "opus-x", effort: "low")))
    }

    @Test func hiddenAgentsTrimmedAndEmptiesDropped() async throws {
        let fake = try Self.fake()
        var state = await Self.state(fake)
        state.setHiddenAgents([" Explore ", "", "Plan"])

        _ = await LeoDelegationOps.write(
            .hiddenAgents, edits: state.edits, document: try #require(state.document), client: fake, revisions: LeoConfigRevisionTracker()
        )

        #expect(await Self.writes(fake).map(\.write) == [.hideAgents(["Explore", "Plan"])])
    }

    @Test func aFormEditWithNoOpenEditorSendsNothing() async throws {
        let fake = try Self.fake()
        let state = await Self.state(fake)

        let outcome = await LeoDelegationOps.write(
            .useFor, edits: state.edits, document: try #require(state.document), client: fake, revisions: LeoConfigRevisionTracker()
        )

        guard case .nothingToSend = outcome.reply else {
            Issue.record("Expected nothing to send")
            return
        }
        #expect(await Self.writes(fake).isEmpty)
    }

    @Test func onlyEditorsBasedOnTheSentRevisionFollowTheWrite() async throws {
        let fake = try Self.fake()
        var state = await Self.state(fake)
        state.beginCellEdit(profile: "deep", role: "coder")
        state.setCellEffort("high")
        await fake.externalDelegationChange(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder"))
        state.adopt(try await fake.delegation(), rebasing: [])
        state.beginUseForEdit(role: "qa")

        let outcome = await LeoDelegationOps.write(
            .enabled(false), edits: state.edits, document: try #require(state.document), client: fake, revisions: LeoConfigRevisionTracker(),
            retryingConflict: true
        )

        guard case .sent(_, let rebasing, _) = outcome.reply else {
            Issue.record("Expected the write to land")
            return
        }
        #expect(rebasing == [.useFor])
    }

    @Test func readsBackWhenReplyHasNoItem() async throws {
        let fake = try Self.fake()

        let readBack = await LeoDelegationOps.readBack(LeoDelegationWriteResult(revision: "r2"), client: fake)

        #expect(readBack?.profiles.map(\.name) == ["deep", "fast"])
        #expect(await fake.calls.contains(.delegation))
    }

    @Test func aReplyWithItsDocumentNeedsNoRead() async throws {
        let fake = try Self.fake()
        let item = LeoDelegationMatrixTests.document()

        let readBack = await LeoDelegationOps.readBack(LeoDelegationWriteResult(revision: "r2", item: item), client: fake)

        #expect(readBack == item)
        #expect(await fake.calls.isEmpty)
    }

    @Test func previewSaysWhyItFailed() async throws {
        let fake = try Self.fake()
        await fake.failNextRead(with: LeoDaemonError.transport("tunnel down"))

        let preview = await LeoDelegationOps.preview("deep", client: fake)

        guard case .failed(let profile, _) = preview else {
            Issue.record("Expected a failure")
            return
        }
        #expect(profile == "deep")
    }
}
