import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoConfigCollectionModelTests {
    private struct Harness {
        let model: LeoConfigCollectionModel
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker
    }

    private static func harness(resource: String = "templates", select: String? = nil) async throws -> Harness {
        let fake = try LeoConfigGolden.client()
        let revisions = LeoConfigRevisionTracker()
        let model = LeoConfigCollectionModel(resource: resource, client: fake, revisions: revisions)
        await model.load()
        if let select { model.select(select) }
        return Harness(model: model, fake: fake, revisions: revisions)
    }

    private static func updates(_ fake: LeoFakeConfigClient) async -> [LeoFakeConfigCall] {
        await fake.calls.filter { if case .update = $0 { true } else { false } }
    }

    // MARK: loading

    @Test func loadingListsTheItemsAndSelectsTheFirst() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.items.map(\.name) == ["coder", "reviewer"])
        #expect(harness.model.selection == "coder")
        #expect(harness.model.draft?.document.name == "coder")
        #expect(!harness.model.sections.isEmpty)
        #expect(!harness.model.isDirty)
    }

    @Test func theActionsComeFromTheSchema() async throws {
        let templates = try await Self.harness()
        let tasks = try await Self.harness(resource: "tasks")

        #expect(templates.model.actions == [.add, .rename, .duplicate, .delete])
        #expect(tasks.model.actions == [.add, .delete])
    }

    @Test func aMissingConfigAPIIsAFailureNotAForm() async throws {
        let model = LeoConfigCollectionModel(resource: "templates", client: try LeoConfigGolden.client(supported: false), revisions: LeoConfigRevisionTracker())
        await model.load()

        guard case .failed = model.phase else {
            Issue.record("Expected failed")
            return
        }
        #expect(model.draft == nil)
    }

    // MARK: editing and saving

    @Test func anEditMakesTheModelDirtyAndRevertClearsIt() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("sonnet"))
        #expect(harness.model.isDirty)
        #expect(harness.model.hasUnsavedChanges)

        harness.model.revertAll()
        #expect(!harness.model.isDirty)
    }

    @Test func saveSendsOnlyTheChangedKeysWithTheRevision() async throws {
        let harness = try await Self.harness()
        let revision = try #require(harness.model.draft?.revision)
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()

        #expect(await Self.updates(harness.fake) == [
            .update(resource: "templates", name: "coder", patch: ["model": .string("sonnet")], ifMatch: revision),
        ])
        #expect(!harness.model.isDirty)
        #expect(harness.model.draft?.value(at: "model") == .string("sonnet"))
        #expect(harness.model.draft?.revision != revision)
    }

    @Test func saveIsDisabledWhileUnchangedOrInvalid() async throws {
        let harness = try await Self.harness()
        #expect(!harness.model.canSave)

        harness.model.set("max_turns", .int(-1))
        #expect(!harness.model.canSave)
        await harness.model.save()
        #expect(await Self.updates(harness.fake).isEmpty)

        harness.model.set("max_turns", .int(5))
        #expect(harness.model.canSave)
    }

    @Test func aWriteElsewhereInTheAppDoesNotConflictThisPane() async throws {
        let harness = try await Self.harness()
        let stale = try #require(harness.model.draft?.revision)
        let other = try await harness.fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: stale)
        harness.revisions.recordWrite(from: stale, to: other.revision)
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()

        #expect(harness.model.conflict == nil)
        #expect(!harness.model.isDirty)
    }

    // MARK: conflict

    @Test func aStaleRevisionOffersReloadAndOverwriteAndKeepsTheEdits() async throws {
        let harness = try await Self.harness()
        let stale = try #require(harness.model.draft?.revision)
        _ = try await harness.fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: stale)
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()

        #expect(harness.model.conflict != nil)
        #expect(harness.model.isDirty)
        #expect(harness.model.draft?.value(at: "model") == .string("sonnet"))
    }

    @Test func reloadAfterAConflictRebasesTheEditsOntoTheNewRevision() async throws {
        let harness = try await Self.harness()
        let stale = try #require(harness.model.draft?.revision)
        let theirs = try await harness.fake.update("templates", name: "coder", patch: ["workspace": .string("/tmp/theirs")], ifMatch: stale)
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()
        await harness.model.reloadAfterConflict()

        #expect(harness.model.conflict == nil)
        #expect(harness.model.draft?.revision == theirs.revision)
        #expect(harness.model.draft?.value(at: "workspace") == .string("/tmp/theirs"))
        #expect(harness.model.draft?.patch == ["model": .string("sonnet")])
    }

    @Test func overwriteResendsThePatchWithTheCurrentRevision() async throws {
        let harness = try await Self.harness()
        let stale = try #require(harness.model.draft?.revision)
        let theirs = try await harness.fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: stale)
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()
        await harness.model.overwrite()

        let sent = await Self.updates(harness.fake).last
        #expect(sent == .update(resource: "templates", name: "coder", patch: ["model": .string("sonnet")], ifMatch: theirs.revision))
        #expect(harness.model.conflict == nil)
        #expect(!harness.model.isDirty)
    }

    @Test func editingAnEnvVariableKeepsTheSecretOneInThePatch() async throws {
        let fake = try LeoConfigGolden.client(secretEnv: true)
        let model = LeoConfigCollectionModel(resource: "templates", client: fake, revisions: LeoConfigRevisionTracker())
        await model.load()
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.replacingEnvEntries(["ANTHROPIC_BASE_URL": "http://other"]))
        let sent = try #require(model.draft?.patch["env"])

        #expect(sent.envEntries == ["ANTHROPIC_BASE_URL": "http://other"])
        #expect(sent.envSecretNames == ["ANTHROPIC_AUTH_TOKEN"])
        await model.save()
        #expect(model.errorMessage == nil)
    }

    // MARK: field errors

    @Test func aRejectedValueLandsOnItsFieldAndKeepsTheEdit() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))
        harness.model.set("model", .string("bogus"))
        await harness.model.save()

        #expect(harness.model.draft?.errors(for: "model") == ["no such model"])
        #expect(!harness.model.canSave)
        #expect(harness.model.isDirty)
        harness.model.set("model", .string("sonnet"))
        #expect(harness.model.canSave)
    }

    @Test func aFailureWithNoFieldIsShownAndKeepsTheEdit() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "disk full", matches: []))
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()

        #expect(harness.model.errorMessage == "disk full")
        #expect(harness.model.isDirty)
    }

    // MARK: restart

    @Test func aSaveThatNeedsAnAgentRestartRaisesThePrompt() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("sonnet"))
        await harness.model.save()

        #expect(harness.model.restartPrompt == LeoConfigRestartRequired(service: false, agents: true))
        harness.model.dismissRestartPrompt()
        #expect(harness.model.restartPrompt == nil)
    }

    @Test func aSaveThatNeedsNoRestartRaisesNoPrompt() async throws {
        let harness = try await Self.harness(resource: "tasks")
        harness.model.set("enabled", .bool(false))
        await harness.model.save()

        #expect(harness.model.restartPrompt == nil)
    }

    // MARK: selecting

    @Test func selectingAnotherItemSwitchesWhenClean() async throws {
        let harness = try await Self.harness()
        harness.model.select("reviewer")

        #expect(harness.model.selection == "reviewer")
        #expect(harness.model.draft?.document.name == "reviewer")
        #expect(harness.model.confirmation == nil)
    }

    @Test func leavingAnItemWithUnsavedEditsAsksFirst() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("sonnet"))
        harness.model.select("reviewer")

        #expect(harness.model.selection == "coder")
        #expect(harness.model.confirmation == .discardChanges(thenSelect: "reviewer"))
        harness.model.cancelConfirmation()
        #expect(harness.model.selection == "coder")
        #expect(harness.model.isDirty)

        harness.model.select("reviewer")
        await harness.model.confirm()
        #expect(harness.model.selection == "reviewer")
        #expect(!harness.model.isDirty)
    }

    // MARK: add, rename, duplicate, delete

    @Test func addingSelectsTheNewItem() async throws {
        let harness = try await Self.harness()
        let revision = try #require(harness.model.draft?.revision)
        await harness.model.add(name: "scribe")

        #expect(await harness.fake.calls.contains(.add(resource: "templates", name: "scribe", values: [:], ifMatch: revision)))
        #expect(harness.model.items.map(\.name) == ["coder", "reviewer", "scribe"])
        #expect(harness.model.selection == "scribe")
    }

    @Test func renamingKeepsTheSelectionOnTheRenamedItem() async throws {
        let harness = try await Self.harness(select: "reviewer")
        await harness.model.rename(to: "auditor")

        #expect(harness.model.items.map(\.name) == ["auditor", "coder"])
        #expect(harness.model.selection == "auditor")
        #expect(harness.model.draft?.document.name == "auditor")
    }

    @Test func duplicatingSelectsTheCopy() async throws {
        let harness = try await Self.harness()
        await harness.model.duplicate(as: "coder2")

        #expect(harness.model.items.map(\.name) == ["coder", "coder2", "reviewer"])
        #expect(harness.model.selection == "coder2")
    }

    @Test func aNameTheDaemonRejectsShowsItsMessage() async throws {
        let harness = try await Self.harness()
        await harness.model.add(name: "coder")

        #expect(harness.model.errorMessage == "That name is already taken")
        #expect(harness.model.items.count == 2)
    }

    @Test func namesAreCheckedBeforeAnythingIsSent() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.nameError("") == "Enter a name")
        #expect(harness.model.nameError("coder") != nil)
        #expect(harness.model.nameError("bad name") != nil)
        #expect(harness.model.nameError("scribe") == nil)
        #expect(harness.model.nameError("coder", excluding: "coder") == nil)
    }

    @Test func deleteConfirmsAndNamesTheItem() async throws {
        let harness = try await Self.harness(select: "reviewer")
        harness.model.requestDelete()

        #expect(harness.model.confirmation == .delete("reviewer"))
        #expect(await harness.fake.calls.allSatisfy { if case .delete = $0 { false } else { true } })
        await harness.model.confirm()

        #expect(harness.model.items.map(\.name) == ["coder"])
        #expect(harness.model.selection == "coder")
    }

    @Test func deletingAnItemInUseShowsWhy() async throws {
        let harness = try await Self.harness(select: "reviewer")
        let revision = try #require(harness.model.draft?.revision)
        let used = try await harness.fake.update("tasks", name: "nightly", patch: ["template": .string("reviewer")], ifMatch: revision)
        harness.revisions.recordWrite(from: revision, to: used.revision)
        harness.model.requestDelete()
        await harness.model.confirm()

        #expect(harness.model.errorMessage == "reviewer is still used by tasks/nightly")
        #expect(harness.model.items.map(\.name) == ["coder", "reviewer"])
    }

    // MARK: reload

    @Test func reloadingWithANewClientKeepsTheEditsAndAdoptsTheNewDocument() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("sonnet"))
        let replacement = try LeoConfigGolden.client()
        _ = try await replacement.update(
            "templates", name: "coder", patch: ["workspace": .string("/tmp/elsewhere")], ifMatch: try await replacement.collection("templates").revision
        )
        await harness.model.reload(using: replacement)

        #expect(harness.model.selection == "coder")
        #expect(harness.model.draft?.value(at: "workspace") == .string("/tmp/elsewhere"))
        #expect(harness.model.draft?.patch == ["model": .string("sonnet")])
        #expect(harness.model.hasUnsavedChanges)
    }

    @Test func reloadingDropsTheSelectionWhenTheItemIsGone() async throws {
        let harness = try await Self.harness(select: "reviewer")
        harness.model.set("model", .string("sonnet"))
        let replacement = try LeoConfigGolden.client()
        _ = try await replacement.delete("templates", name: "reviewer", ifMatch: try await replacement.collection("templates").revision)
        await harness.model.reload(using: replacement)

        #expect(harness.model.selection == "coder")
        #expect(!harness.model.isDirty)
    }

    @Test func discardingThroughThePaneProtocolDropsTheDraft() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("sonnet"))
        harness.model.discardChanges()

        #expect(!harness.model.hasUnsavedChanges)
    }
}
