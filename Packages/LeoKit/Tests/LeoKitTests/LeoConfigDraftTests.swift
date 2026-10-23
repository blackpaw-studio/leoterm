import Foundation
import Testing

@testable import LeoKit

struct LeoConfigDraftTests {
    private static let schema = (try? LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")) ?? LeoConfigSchema(resources: [])

    private static func draft(_ name: String = "template_coder", resource: String = "templates") throws -> LeoConfigDraft {
        let validator = LeoConfigValidator(
            resource: try #require(schema.resource(resource)), harnesses: schema.harnesses, namePattern: schema.namePattern
        )
        return LeoConfigDraft(document: try LeoConfigFixtures.decode(LeoConfigDocument.self, name), validator: validator)
    }

    // MARK: dirty state

    @Test func aFreshDraftIsCleanAndCannotBeSaved() throws {
        let draft = try Self.draft()

        #expect(!draft.isDirty)
        #expect(!draft.canSave)
        #expect(draft.patch.isEmpty)
        #expect(draft.revision == "sha256:aa11")
    }

    @Test func anEditMakesTheDraftAndItsFieldDirty() throws {
        var draft = try Self.draft()
        draft.set("model", .string("claude-sonnet-5-5"))

        #expect(draft.isDirty)
        #expect(draft.isDirty("model"))
        #expect(!draft.isDirty("workspace"))
        #expect(draft.canSave)
        #expect(draft.value(at: "model") == .string("claude-sonnet-5-5"))
    }

    @Test func settingTheBaseValueBackIsNotDirty() throws {
        var draft = try Self.draft()
        draft.set("max_turns", .int(5))
        draft.set("max_turns", .null)

        #expect(!draft.isDirty)
        #expect(!draft.canSave)
    }

    @Test func emptyTextAndEmptyCollectionsEqualUnset() {
        var draft = LeoConfigDraft(document: LeoConfigDocument(revision: "r", values: [
            "text": .null, "blank": .string(""), "list": .null, "map": .null, "full": .list([.string("x")]),
        ]))
        draft.set("text", .string(""))
        draft.set("blank", .null)
        draft.set("list", .list([]))
        draft.set("map", .map([:]))
        #expect(!draft.isDirty)

        draft.set("full", .list([]))
        #expect(draft.patch == ["full": .list([])])
    }

    @Test func zeroAndFalseAreRealValuesNotUnset() {
        var draft = LeoConfigDraft(document: LeoConfigDocument(revision: "r", values: ["n": .null, "b": .null]))
        draft.set("n", .int(0))
        draft.set("b", .bool(false))
        #expect(draft.isDirty("n"))
        #expect(draft.isDirty("b"))
    }

    @Test func aMissingKeyReadsAsNullAndNullEqualsMissing() throws {
        var draft = try Self.draft()
        #expect(draft.value(at: "no_such_key") == .null)
        draft.set("no_such_key", .null)
        #expect(!draft.isDirty)
    }

    @Test func revertingOneFieldKeepsTheOthers() throws {
        var draft = try Self.draft()
        draft.set("model", .string("x"))
        draft.set("workspace", .string("~/other"))
        draft.revert("model")

        #expect(!draft.isDirty("model"))
        #expect(draft.isDirty("workspace"))
        #expect(draft.value(at: "model") == .string(""))
    }

    @Test func revertingAllDropsEveryEditAndError() throws {
        var draft = try Self.draft()
        draft.set("model", .string("x"))
        draft = draft.applying(serverErrors: [LeoConfigFieldError(field: "model", message: "no")])
        draft.revert()

        #expect(!draft.isDirty)
        #expect(draft.errors(for: "model").isEmpty)
        #expect(draft.allErrors.isEmpty)
    }

    // MARK: patch

    @Test func theSaveCarriesOnlyTheChangedTopLevelKeys() throws {
        var draft = try Self.draft()
        draft.set("model", .string("claude-sonnet-5-5"))
        draft.set("max_turns", .int(7))

        #expect(draft.patch == ["model": .string("claude-sonnet-5-5"), "max_turns": .int(7)])
    }

    @Test func clearingAValueSendsNull() throws {
        var draft = try Self.draft()
        draft.set("system_prompt", .null)

        #expect(draft.patch == ["system_prompt": .null])
    }

    @Test func aSubsectionEditSendsTheWholeSubsectionObject() throws {
        var draft = try Self.draft()
        draft.set("push.enabled", .null)
        draft.set("permissions.allow", .list([.string("Bash(ls)")]))

        #expect(Set(draft.patch.keys) == ["push", "permissions"])
        #expect(draft.patch["push"]?.objectValue == ["enabled": .null])
        #expect(draft.patch["permissions"]?.objectValue == ["allow": .list([.string("Bash(ls)")])])
        #expect(draft.isDirty("push.enabled"))
    }

    @Test func aHarnessOptionEditKeepsTheScopesOtherOptions() throws {
        var draft = try Self.draft()
        draft.set("harness_options.permission_mode", .string("acceptEdits"))

        let options = try #require(draft.patch["harness_options"]?.objectValue)
        #expect(options["permission_mode"] == .string("acceptEdits"))
        #expect(options["allowed_tools"] == .list([.string("Read"), .string("Edit")]))
        #expect(options["settings"] == .string("theme: dark\n"))
    }

    @Test func changingTheHarnessDropsTheOldHarnessOptions() throws {
        var draft = try Self.draft()
        draft.set("harness", .string("codex"))
        draft.set("harness_options.sandbox", .string("workspace-write"))

        let options = try #require(draft.patch["harness_options"]?.objectValue)
        #expect(options == ["sandbox": .string("workspace-write")])
        #expect(draft.patch["harness"] == .string("codex"))
        #expect(draft.currentHarness == "codex")
    }

    @Test func changingTheHarnessAloneStillSendsTheOptionsSoStaleOnesAreCleared() throws {
        var draft = try Self.draft()
        draft.set("harness", .string("codex"))

        #expect(draft.patch["harness_options"]?.objectValue == [:])
    }

    @Test func theHarnessFallsBackToTheInheritedOne() throws {
        var draft = try Self.draft()
        #expect(draft.currentHarness == "claude")
        draft.set("harness", .string("codex"))
        #expect(draft.currentHarness == "codex")
        draft.set("harness", .string(""))
        #expect(draft.currentHarness == "claude")
    }

    // MARK: validation and errors

    @Test func anInvalidValueBlocksSaveUntilFixed() throws {
        var draft = try Self.draft()
        draft.set("max_turns", .int(0))

        #expect(draft.isDirty)
        #expect(!draft.canSave)
        #expect(draft.errors(for: "max_turns") == ["Must be at least 1"])

        draft.set("max_turns", .int(3))
        #expect(draft.canSave)
        #expect(draft.allErrors.isEmpty)
    }

    @Test func aRequiredFieldClearedBlocksSave() throws {
        var draft = try Self.draft()
        draft.set("workspace", .string(""))

        #expect(!draft.canSave)
        #expect(draft.errors(for: "workspace") == ["Required"])
    }

    @Test func serverErrorsShowOnTheirFieldAndBlockSave() throws {
        var draft = try Self.draft()
        draft.set("model", .string("x"))
        draft = draft.applying(serverErrors: [
            LeoConfigFieldError(field: "model", message: "unknown model"),
            LeoConfigFieldError(field: "", message: "templates.old: workspace is required"),
        ])

        #expect(draft.errors(for: "model") == ["unknown model"])
        #expect(draft.formErrors == ["templates.old: workspace is required"])
        #expect(!draft.canSave)
    }

    @Test func editingAFieldClearsItsServerErrorAndTheFormLevelOnes() throws {
        var draft = try Self.draft()
        draft.set("model", .string("x"))
        draft.set("max_turns", .int(2))
        draft = draft.applying(serverErrors: [
            LeoConfigFieldError(field: "model", message: "unknown model"),
            LeoConfigFieldError(field: "max_turns", message: "too many"),
            LeoConfigFieldError(field: "", message: "form"),
        ])
        draft.set("model", .string("y"))

        #expect(draft.errors(for: "model").isEmpty)
        #expect(draft.errors(for: "max_turns") == ["too many"])
        #expect(draft.formErrors.isEmpty)
    }

    @Test func aServerErrorOnAnUnknownFieldBecomesAFormError() throws {
        var draft = try Self.draft()
        draft.set("model", .string("x"))
        draft = draft.applying(serverErrors: [LeoConfigFieldError(field: "future_field", message: "bad")])

        #expect(draft.formErrors == ["future_field: bad"])
    }

    // MARK: rebase

    @Test func rebasingKeepsEditsThatStillDifferAndAdoptsTheNewBase() throws {
        var draft = try Self.draft()
        draft.set("model", .string("mine"))
        draft.set("workspace", .string("~/elsewhere"))
        let newDocument = LeoConfigDocument(
            revision: "sha256:cc33", name: "coder",
            values: ["workspace": .string("~/elsewhere"), "model": .string("theirs"), "max_turns": .int(9)],
            inherited: ["harness": .string("claude")], effectiveHarness: "claude"
        )
        let rebased = draft.rebased(onto: newDocument)

        #expect(rebased.revision == "sha256:cc33")
        #expect(rebased.patch == ["model": .string("mine")])
        #expect(rebased.value(at: "max_turns") == .int(9))
        #expect(!rebased.isDirty("workspace"))
    }

    @Test func rebasingDropsServerErrorsAndRevalidates() throws {
        var draft = try Self.draft()
        draft.set("max_turns", .int(0))
        draft = draft.applying(serverErrors: [LeoConfigFieldError(field: "model", message: "no")])
        let rebased = draft.rebased(onto: try LeoConfigFixtures.decode(LeoConfigDocument.self, "template_coder"))

        #expect(rebased.errors(for: "model").isEmpty)
        #expect(rebased.errors(for: "max_turns") == ["Must be at least 1"])
    }

    @Test func aRebasedNestedEditSendsTheFreshSiblings() throws {
        var draft = try Self.draft()
        draft.set("harness_options.permission_mode", .string("acceptEdits"))
        let newDocument = LeoConfigDocument(
            revision: "r2", name: "coder",
            values: ["harness_options": .object(["allowed_tools": .list([.string("Grep")])])],
            effectiveHarness: "claude"
        )
        let options = try #require(draft.rebased(onto: newDocument).patch["harness_options"]?.objectValue)

        #expect(options == ["permission_mode": .string("acceptEdits"), "allowed_tools": .list([.string("Grep")])])
    }

    // MARK: singletons and no validator

    @Test func aSingletonDraftWorksWithoutAValidator() throws {
        var draft = LeoConfigDraft(document: try LeoConfigFixtures.decode(LeoConfigDocument.self, "web"))
        draft.set("port", .int(9000))

        #expect(draft.canSave)
        #expect(draft.patch == ["port": .int(9000)])
        #expect(draft.document.name == nil)
    }
}
