import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoConfigSingletonModelTests {
    private struct Harness {
        let model: LeoConfigSingletonModel
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker
    }

    private static func harness(resource: String = "defaults") async throws -> Harness {
        let fake = try LeoConfigGolden.client()
        let revisions = LeoConfigRevisionTracker()
        let model = LeoConfigSingletonModel(resource: resource, client: fake, revisions: revisions)
        await model.load()
        return Harness(model: model, fake: fake, revisions: revisions)
    }

    private static func updates(_ fake: LeoFakeConfigClient) async -> [LeoFakeConfigCall] {
        await fake.calls.filter { if case .update = $0 { true } else { false } }
    }

    private static func list(_ names: String...) -> LeoConfigValue {
        .list(names.map(LeoConfigValue.string))
    }

    // MARK: loading

    @Test func loadingShowsTheSingletonDocumentAsAForm() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.phase == .loaded)
        #expect(harness.model.title == "Defaults")
        #expect(harness.model.draft?.value(at: "model") == .string("sonnet"))
        #expect(!harness.model.sections.isEmpty)
        #expect(!harness.model.isDirty)
    }

    @Test func theFormHasTheHarnessOptionsAndPushSections() async throws {
        let harness = try await Self.harness()
        let kinds = harness.model.sections.map(\.kind)

        #expect(kinds.contains(.harnessOptions))
        #expect(kinds.contains(.subsection))
    }

    @Test func aMissingConfigAPIIsAFailureNotAForm() async throws {
        let model = LeoConfigSingletonModel(
            resource: "defaults", client: try LeoConfigGolden.client(supported: false), revisions: LeoConfigRevisionTracker()
        )
        await model.load()

        guard case .failed = model.phase else {
            Issue.record("Expected failed")
            return
        }
        #expect(model.draft == nil)
    }

    @Test func aResourceTheDaemonDoesNotServeIsAFailure() async throws {
        let model = LeoConfigSingletonModel(resource: "nope", client: try LeoConfigGolden.client(), revisions: LeoConfigRevisionTracker())
        await model.load()

        guard case .failed = model.phase else {
            Issue.record("Expected failed")
            return
        }
    }

    // MARK: editing and saving

    @Test func anEditMakesTheModelDirtyAndRevertClearsIt() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        #expect(harness.model.isDirty)
        #expect(harness.model.hasUnsavedChanges)

        harness.model.revertAll()
        #expect(!harness.model.isDirty)
    }

    @Test func saveSendsOnlyTheChangedKeyWithTheRevisionAndAdoptsTheResult() async throws {
        let harness = try await Self.harness()
        let revision = try #require(harness.model.draft?.revision)
        harness.model.set("model", .string("opus"))
        await harness.model.save()

        #expect(await Self.updates(harness.fake) == [.update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: revision)])
        #expect(!harness.model.isDirty)
        #expect(harness.model.draft?.value(at: "model") == .string("opus"))
        #expect(harness.model.draft?.revision != revision)
    }

    @Test func aNestedEditSendsOnlyItsOwnKey() async throws {
        let harness = try await Self.harness()
        harness.model.set("push.finished", .bool(false))
        await harness.model.save()

        #expect(await Self.updates(harness.fake).map(Self.patch) == [["push": .object(["finished": .bool(false)])]])
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
        harness.model.set("model", .string("opus"))
        await harness.model.save()

        #expect(harness.model.conflict == nil)
        #expect(!harness.model.isDirty)
    }

    @Test func anEditMadeWhileASaveIsInFlightIsKept() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        await harness.fake.holdWrites()

        let saving = Task { await harness.model.save() }
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }
        harness.model.set("max_turns", .int(20))
        await harness.fake.releaseWrites()
        await saving.value

        #expect(harness.model.draft?.patch == ["max_turns": .int(20)])
        #expect(harness.model.draft?.value(at: "model") == .string("opus"))
    }

    // MARK: conflict

    @Test func aStaleRevisionOffersReloadAndOverwriteAndKeepsTheEdits() async throws {
        let harness = try await Self.harness()
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(3)])
        harness.model.set("model", .string("opus"))
        await harness.model.save()

        #expect(harness.model.conflict != nil)
        #expect(harness.model.isDirty)
        #expect(harness.model.draft?.value(at: "model") == .string("opus"))
        #expect(!harness.model.canSave)
    }

    @Test func reloadAfterAConflictRebasesTheEditsOntoTheNewDocument() async throws {
        let harness = try await Self.harness()
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(3)])
        harness.model.set("model", .string("opus"))
        await harness.model.save()
        await harness.model.reloadAfterConflict()

        #expect(harness.model.conflict == nil)
        #expect(harness.model.draft?.value(at: "max_turns") == .int(3))
        #expect(harness.model.draft?.patch == ["model": .string("opus")])
        #expect(harness.model.draft?.revision == (await harness.fake.currentRevision))
    }

    @Test func reloadReplaysAnOrderedListEditAsTypedOverTheOtherWritersList() async throws {
        let harness = try await Self.harness()
        harness.model.set("environments", Self.list("base", "work"))
        await harness.fake.externalChange("defaults", values: ["environments": Self.list("base", "ci")])
        await harness.model.save()
        await harness.model.reloadAfterConflict()

        #expect(harness.model.draft?.value(at: "environments") == Self.list("base", "work"))
    }

    @Test func overwriteSendsOnlyTheUsersEditsOverTheCurrentFile() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(3)])
        let current = await harness.fake.currentRevision
        await harness.model.save()
        await harness.model.overwrite()

        let sent = try #require(await Self.updates(harness.fake).last)
        #expect(sent == .update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: current))
        let stored = try await harness.fake.document("defaults").values
        #expect(stored["model"] == .string("opus"))
        #expect(stored["max_turns"] == .int(3))
        #expect(harness.model.conflict == nil)
        #expect(!harness.model.isDirty)
    }

    @Test func overwriteSendsAnOrderedListAsTypedOverTheOtherWritersChange() async throws {
        let harness = try await Self.harness()
        harness.model.set("environments", Self.list("base", "work"))
        await harness.fake.externalChange("defaults", values: ["environments": Self.list("base", "ci")])
        await harness.model.save()
        await harness.model.overwrite()

        let stored = try await harness.fake.document("defaults").values
        #expect(stored["environments"] == Self.list("base", "work"))
        #expect(harness.model.conflict == nil)
    }

    @Test func overwriteStaysAConflictWhenTheFileMovesAgain() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(3)])
        await harness.model.save()
        await harness.fake.holdWrites()
        let overwriting = Task { await harness.model.overwrite() }
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(4)])
        await harness.fake.releaseWrites()
        await overwriting.value

        #expect(harness.model.conflict != nil)
        #expect(harness.model.isDirty)
        #expect(try await harness.fake.document("defaults").values["model"] == .string("sonnet"))
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
        harness.model.set("model", .string("opus"))
        #expect(harness.model.canSave)
    }

    @Test func aFailureWithNoFieldIsShownAndKeepsTheEdit() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "disk full", matches: []))
        harness.model.set("model", .string("opus"))
        await harness.model.save()

        #expect(harness.model.errorMessage == "disk full")
        #expect(harness.model.isDirty)
    }

    // MARK: restart

    @Test func aDefaultsSaveRaisesTheAgentsRestartPrompt() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        await harness.model.save()

        #expect(harness.model.restartPrompt == LeoConfigRestartRequired(service: false, agents: true))
        harness.model.dismissRestartPrompt()
        #expect(harness.model.restartPrompt == nil)
    }

    @Test func aClientSaveNeedsNoRestart() async throws {
        let harness = try await Self.harness(resource: "client")
        harness.model.set("default_host", .string(""))
        await harness.model.save()

        #expect(harness.model.restartPrompt == nil)
    }

    // MARK: reload on reconnect

    @Test func reloadingWithANewClientKeepsTheEditsAndAdoptsTheNewDocument() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        harness.model.set("environments", Self.list("base", "work"))
        let replacement = try LeoConfigGolden.client()
        await replacement.externalChange("defaults", values: ["max_turns": .int(3), "environments": Self.list("base", "ci")])
        await harness.model.reload(using: replacement)

        #expect(harness.model.draft?.value(at: "max_turns") == .int(3))
        #expect(harness.model.draft?.value(at: "environments") == Self.list("base", "work"))
        #expect(harness.model.draft?.patch["model"] == .string("opus"))
        #expect(harness.model.hasUnsavedChanges)
    }

    @Test func aCleanReloadAdoptsTheNewDocument() async throws {
        let harness = try await Self.harness()
        let replacement = try LeoConfigGolden.client()
        await replacement.externalChange("defaults", values: ["model": .string("haiku")])
        await harness.model.reload(using: replacement)

        #expect(harness.model.draft?.value(at: "model") == .string("haiku"))
        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test func discardingChangesDropsTheDraftEdits() async throws {
        let harness = try await Self.harness()
        harness.model.set("model", .string("opus"))
        harness.model.discardChanges()

        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.draft?.value(at: "model") == .string("sonnet"))
    }

    // MARK: references

    @Test func aReferenceFieldPicksFromTheNamesItIsGiven() async throws {
        let fake = try LeoConfigGolden.client()
        let model = LeoConfigSingletonModel(
            resource: "client", client: fake, revisions: LeoConfigRevisionTracker(), references: ["hosts": ["remote"]],
            resourceTransform: { $0.referencing("default_host", to: "hosts", emptyLabel: "none") }
        )
        await model.load()

        let control = model.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote"], emptyLabel: "none"))
    }

    @Test func namesThatChangeUnderAnOpenFormAreChoosable() async throws {
        let fake = try LeoConfigGolden.client()
        let model = LeoConfigSingletonModel(
            resource: "client", client: fake, revisions: LeoConfigRevisionTracker(), references: ["hosts": ["remote"]],
            resourceTransform: { $0.referencing("default_host", to: "hosts", emptyLabel: "none") }
        )
        await model.load()
        model.set("default_host", .string("staging"))
        #expect(!model.canSave)

        model.setReferences(["hosts": ["remote", "staging"]])

        #expect(model.canSave)
        let control = model.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote", "staging"], emptyLabel: "none"))
    }

    private static func patch(_ call: LeoFakeConfigCall) -> [String: LeoConfigValue] {
        guard case .update(_, _, let patch, _) = call else { return [:] }
        return patch
    }
}
