import Foundation
import Testing

@testable import LeoKit

struct LeoConfigValidatorTests {
    private static let schema = (try? LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")) ?? LeoConfigSchema(resources: [])

    private static func validator(
        _ resource: String, references: [String: [String]] = [:]
    ) throws -> LeoConfigValidator {
        LeoConfigValidator(
            resource: try #require(schema.resource(resource)), harnesses: schema.harnesses,
            namePattern: schema.namePattern, references: references
        )
    }

    private func messages(_ validator: LeoConfigValidator, _ values: [String: LeoConfigValue], harness: String? = "claude") -> [String: String] {
        Dictionary(
            validator.errors(values: { values[$0] ?? .null }, harness: harness).map { ($0.field, $0.message) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test func aCleanTemplatePasses() throws {
        let errors = messages(try Self.validator("templates"), ["workspace": .string("~/code"), "max_turns": .int(5), "idle_suspend_after": .string("1h30m")])
        #expect(errors.isEmpty)
    }

    @Test(arguments: [LeoConfigValue.null, .string("")])
    func aRequiredFieldMustBeFilled(value: LeoConfigValue) throws {
        let errors = messages(try Self.validator("tasks"), ["schedule": value, "prompt_file": .string("p.md")])
        #expect(errors["schedule"] == "Required")
    }

    @Test func anOptionalFieldMayBeEmpty() throws {
        #expect(messages(try Self.validator("templates"), ["workspace": .string("w"), "model": .string("")]).isEmpty)
    }

    @Test(arguments: [(-1, "Must be at least 0"), (-3, "Must be at least 0")])
    func numbersStayInRange(value: Int, message: String) throws {
        let errors = messages(try Self.validator("templates"), ["workspace": .string("w"), "max_turns": .int(value)])
        #expect(errors["max_turns"] == message)
    }

    @Test func theUpperBoundIsEnforcedAndBoundsAreInclusive() throws {
        let validator = try Self.validator("web")
        #expect(messages(validator, ["port": .int(65536)])["port"] == "Must be at most 65535")
        #expect(messages(validator, ["port": .int(0)])["port"] == "Must be at least 1")
        for value in [1, 65535] { #expect(messages(validator, ["port": .int(value)]).isEmpty) }
        #expect(messages(try Self.validator("templates"), ["workspace": .string("w"), "max_turns": .int(0)]).isEmpty)
    }

    @Test func textInANumberFieldIsNotANumber() throws {
        let errors = messages(try Self.validator("templates"), ["workspace": .string("w"), "max_turns": .string("abc")])
        #expect(errors["max_turns"] == "Must be a whole number")
    }

    @Test func anEnumMustBeOneOfItsOptions() throws {
        let validator = try Self.validator("templates")
        #expect(messages(validator, ["workspace": .string("w"), "harness": .string("gemini")])["harness"] == "Choose one of the listed values")
        #expect(messages(validator, ["workspace": .string("w"), "harness": .string("codex")]).isEmpty)
        #expect(messages(validator, ["workspace": .string("w"), "harness": .string("")]).isEmpty)
    }

    @Test func aReferenceMustNameAnExistingItem() throws {
        let validator = try Self.validator("tasks", references: ["templates": ["coder", "reviewer"]])
        let base: [String: LeoConfigValue] = ["schedule": .string("0 3 * * *"), "prompt_file": .string("p.md")]

        #expect(messages(validator, base.merging(["template": .string("ghost")]) { $1 })["template"] == "No templates named “ghost”")
        #expect(messages(validator, base.merging(["template": .string("coder")]) { $1 }).isEmpty)
        #expect(messages(validator, base.merging(["template": .string("")]) { $1 }).isEmpty)
    }

    @Test func aReferenceToAnUnloadedCollectionIsNotChecked() throws {
        let errors = messages(try Self.validator("tasks"), ["schedule": .string("* * * * *"), "prompt_file": .string("p.md"), "template": .string("ghost")])
        #expect(errors.isEmpty)
    }

    @Test(arguments: ["30m", "1h30m", "1.5h", "250ms", "2h45m30s", "0", "-5s", "1µs"])
    func goDurationsPass(text: String) throws {
        let errors = messages(try Self.validator("templates"), ["workspace": .string("w"), "idle_suspend_after": .string(text)])
        #expect(errors.isEmpty)
    }

    @Test(arguments: ["30", "m", "1d", "1 h", "h1", "1h-5m", "1.h2"])
    func nonDurationsFail(text: String) throws {
        let errors = messages(try Self.validator("templates"), ["workspace": .string("w"), "idle_suspend_after": .string(text)])
        #expect(errors["idle_suspend_after"] == "Not a valid duration (try 30m or 1h30m)")
    }

    @Test func aMapNeedsNonEmptyKeysWithoutEquals() throws {
        let validator = try Self.validator("environments")
        #expect(messages(validator, ["env": .map(["A": "1", "B": ""])]).isEmpty)
        #expect(messages(validator, ["env": .map(["": "1"])])["env"] == "Variable names can’t be empty")
        #expect(messages(validator, ["env": .map(["A=B": "1"])])["env"] == "Variable names can’t contain “=”")
    }

    @Test func aPatternConstrainsNonEmptyText() throws {
        // No registered daemon field has a pattern yet, so the field is synthetic.
        let resource = LeoConfigResource(key: "r", fields: [
            LeoConfigField(key: "address", type: .string, constraints: LeoConfigConstraints(required: true, pattern: "^[^\\s]+$")),
        ])
        let validator = LeoConfigValidator(resource: resource)
        #expect(messages(validator, ["address": .string("10.0.0.1:8370")]).isEmpty)
        #expect(messages(validator, ["address": .string("has space")])["address"] == "Doesn’t match the expected format")
        #expect(messages(validator, ["address": .string("")])["address"] == "Required")
    }

    @Test func subsectionFieldsAreCheckedUnderTheirPath() throws {
        let fields = try Self.validator("templates").fields(harness: "claude").map(\.path)
        #expect(fields.contains("permissions.can_spawn"))
        #expect(fields.contains("push.needs_input"))
    }

    @Test func harnessOptionsAreCheckedAgainstTheCurrentHarnessOnly() throws {
        let validator = try Self.validator("templates")
        let claude = validator.fields(harness: "claude").map(\.path)
        let codex = validator.fields(harness: "codex").map(\.path)

        #expect(claude.contains("harness_options.permission_mode"))
        #expect(claude.contains("harness_options.bypass_permissions"))
        #expect(!codex.contains("harness_options.bypass_permissions"))
        #expect(codex.filter { $0.hasPrefix("harness_options.") } == ["harness_options.permission_mode"])
        #expect(validator.fields(harness: nil).allSatisfy { !$0.path.hasPrefix("harness_options.") })

        let errors = messages(validator, ["workspace": .string("w"), "harness_options.permission_mode": .string("bogus")], harness: "claude")
        #expect(errors["harness_options.permission_mode"] == "Choose one of the listed values")
        // `plan` is a claude mode; codex has its own list under the same key.
        let plan: [String: LeoConfigValue] = ["workspace": .string("w"), "harness_options.permission_mode": .string("plan")]
        #expect(messages(validator, plan, harness: "claude").isEmpty)
        #expect(messages(validator, plan, harness: "codex")["harness_options.permission_mode"] == "Choose one of the listed values")
    }

    @Test func aResourceWithoutHarnessOptionsHasNone() throws {
        #expect(try Self.validator("web").fields(harness: "claude").allSatisfy { !$0.path.hasPrefix("harness_options.") })
    }

    @Test func unknownAndSecretFieldsAreNeverFlagged() throws {
        let resource = LeoConfigResource(key: "r", fields: [
            LeoConfigField(key: "tint", type: .unknown("color")),
            LeoConfigField(key: "token", type: .secret),
        ])
        let validator = LeoConfigValidator(resource: resource)
        #expect(validator.errors(values: { _ in .string("anything") }, harness: nil).isEmpty)
    }

    // MARK: names

    @Test(arguments: ["coder", "my-template_2", "a.b", "X"])
    func goodNamesPass(name: String) throws {
        #expect(try Self.validator("templates").nameError(name, existing: []) == nil)
    }

    @Test(arguments: [("", "Enter a name"), ("has space", nil), ("slash/name", nil), ("émile", nil)])
    func badNamesAreRejected(name: String, message: String?) throws {
        let error = try #require(try Self.validator("templates").nameError(name, existing: []))
        if let message { #expect(error == message) } else { #expect(error.hasPrefix("Names can’t contain")) }
    }

    @Test func aTakenNameIsRejected() throws {
        let validator = try Self.validator("templates")
        #expect(validator.nameError("coder", existing: ["coder", "reviewer"]) == "That name is already taken")
        #expect(validator.nameError("Coder", existing: ["coder"]) == nil)
    }

    @Test func renamingToTheCurrentNameIsNotATaken() throws {
        let validator = try Self.validator("templates")
        #expect(validator.nameError("coder", existing: ["coder"], excluding: "coder") == nil)
    }

    @Test func withoutAPatternAnyNonEmptyNameIsFine() {
        let validator = LeoConfigValidator(resource: LeoConfigResource(key: "r"))
        #expect(validator.nameError("anything goes", existing: []) == nil)
    }
}
