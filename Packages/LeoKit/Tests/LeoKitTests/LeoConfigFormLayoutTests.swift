import Foundation
import Testing

@testable import LeoKit

struct LeoConfigFormLayoutTests {
    private static let schema = (try? LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")) ?? LeoConfigSchema(resources: [])
    private static let link = URL(string: "https://leo.example.com/config")

    private static func layout(
        _ resource: String, _ document: String, references: [String: [String]] = [:], link: URL? = link, edit: (inout LeoConfigDraft) -> Void = { _ in }
    ) throws -> [LeoConfigFormSection] {
        var draft = LeoConfigDraft(document: try LeoConfigFixtures.decode(LeoConfigDocument.self, document))
        edit(&draft)
        return LeoConfigFormLayout.sections(
            resource: try #require(schema.resource(resource)), harnesses: schema.harnesses,
            draft: draft, references: references, webLink: link
        )
    }

    /// One field of `type` in a throwaway resource, laid out against `values`.
    private static func control(
        _ field: LeoConfigField, values: [String: LeoConfigValue] = [:], inherited: [String: LeoConfigValue] = [:],
        references: [String: [String]] = [:]
    ) -> LeoConfigControl? {
        let draft = LeoConfigDraft(document: LeoConfigDocument(revision: "r", values: values, inherited: inherited, effectiveHarness: "claude"))
        let sections = LeoConfigFormLayout.sections(
            resource: LeoConfigResource(key: "r", fields: [field]), harnesses: [:], draft: draft, references: references, webLink: link
        )
        return sections.first?.rows.first?.control
    }

    // MARK: one control per field type

    @Test func aStringIsATextField() {
        #expect(Self.control(LeoConfigField(key: "k", type: .string)) == .text(placeholder: nil))
    }

    @Test func aMultilineStringIsATextArea() {
        #expect(Self.control(LeoConfigField(key: "k", type: .string, multiline: true)) == .multiline)
    }

    @Test func aCronFormatIsACronField() {
        #expect(Self.control(LeoConfigField(key: "k", type: .string, format: "cron")) == .cron)
    }

    @Test func anIntIsANumberFieldWithItsBounds() {
        let field = LeoConfigField(key: "k", type: .int, constraints: LeoConfigConstraints(min: 1, max: 9))
        #expect(Self.control(field) == .number(min: 1, max: 9, placeholder: nil))
    }

    @Test func aPlainBoolIsAToggleAndANullableOneIsATriState() {
        #expect(Self.control(LeoConfigField(key: "k", type: .bool)) == .toggle)
        #expect(Self.control(LeoConfigField(key: "k", type: .bool, nullable: true)) == .triState)
    }

    @Test func anEnumIsAPickerOverItsOptions() {
        let options = [LeoConfigOption(value: "", label: "Inherit"), LeoConfigOption(value: "a", label: "A")]
        #expect(Self.control(LeoConfigField(key: "k", type: .enum, options: options)) == .picker(options: options))
    }

    @Test func aReferenceIsAPickerOverTheReferencedNames() {
        let field = LeoConfigField(key: "k", type: .reference, references: "templates", emptyLabel: "none")
        #expect(
            Self.control(field, references: ["templates": ["a", "b"]])
                == .referencePicker(collection: "templates", names: ["a", "b"], emptyLabel: "none")
        )
    }

    @Test func aReferenceWithoutAnEmptyLabelOffersNone() {
        let field = LeoConfigField(key: "k", type: .reference, references: "hosts")
        #expect(Self.control(field) == .referencePicker(collection: "hosts", names: [], emptyLabel: "None"))
    }

    @Test func aListIsAListEditorAndAMapIsAKeyValueEditor() {
        #expect(Self.control(LeoConfigField(key: "k", type: .list)) == .list)
        #expect(Self.control(LeoConfigField(key: "k", type: .map)) == .keyValue)
    }

    @Test func aDurationIsADurationFieldWithItsDefaultAsPlaceholder() {
        let field = LeoConfigField(key: "k", type: .duration, defaultValue: .string("30m"))
        #expect(Self.control(field) == .duration(placeholder: "30m"))
    }

    @Test func aYAMLOptionIsAMonospacedEditor() {
        #expect(Self.control(LeoConfigField(key: "k", type: .yaml)) == .yaml)
    }

    @Test(arguments: [
        (LeoConfigValue.secret(isSet: true), LeoConfigSecretState.set),
        (.secret(isSet: false), .notSet),
        (.secretReplace("x"), .replacing),
        (.secretClear, .clearing),
        (.null, .notSet),
    ])
    func aSecretShowsWhetherItIsSetAndWhatIsPending(value: LeoConfigValue, state: LeoConfigSecretState) {
        #expect(Self.control(LeoConfigField(key: "k", type: .secret), values: ["k": value]) == .secret(state))
    }

    @Test func anUnknownTypeIsReadOnlyWithAWebLink() {
        let field = LeoConfigField(key: "k", type: .unknown("color"))
        #expect(Self.control(field) == .readOnlyUnknown(typeName: "color", webLink: Self.link))
    }

    @Test func anUnknownTypeWithoutALinkIsReadOnlyTextOnly() throws {
        let sections = LeoConfigFormLayout.sections(
            resource: LeoConfigResource(key: "r", fields: [LeoConfigField(key: "k", type: .unknown("color"))]),
            harnesses: [:], draft: LeoConfigDraft(document: LeoConfigDocument(revision: "r", values: [:])), references: [:], webLink: nil
        )
        #expect(sections.first?.rows.first?.control == .readOnlyUnknown(typeName: "color", webLink: nil))
    }

    // MARK: placeholders

    @Test func anInheritedValueIsThePlaceholder() {
        let field = LeoConfigField(key: "model", type: .string)
        #expect(Self.control(field, inherited: ["model": .string("claude-opus-5-5")]) == .text(placeholder: "inherit: claude-opus-5-5"))
    }

    @Test func aDefaultIsThePlaceholderWhenNothingIsInherited() {
        let field = LeoConfigField(key: "bind", type: .string, defaultValue: .string("127.0.0.1"))
        #expect(Self.control(field) == .text(placeholder: "127.0.0.1"))
    }

    @Test func aNumberDefaultIsThePlaceholder() {
        let field = LeoConfigField(key: "port", type: .int, defaultValue: .int(8370))
        #expect(Self.control(field) == .number(min: nil, max: nil, placeholder: "8370"))
    }

    // MARK: sections

    @Test func groupsComeFirstInRegistryOrderThenOptionsSubsectionsAndAdvanced() throws {
        let sections = try Self.layout("templates", "template_coder")

        #expect(sections.map(\.title) == ["General", "Limits", "Harness options", "Permissions", "Push", "Advanced"])
        #expect(sections.map(\.kind) == [.group, .group, .harnessOptions, .subsection, .subsection, .advanced])
    }

    @Test func rowsKeepTheRegistryOrderWithinAGroup() throws {
        let sections = try Self.layout("templates", "template_coder")

        #expect(sections[0].rows.map(\.path) == ["workspace", "model", "harness", "system_prompt", "environments"])
        #expect(sections[1].rows.map(\.path) == ["max_turns", "idle_timeout", "idle_suspend"])
    }

    @Test func advancedFieldsGatherLastIncludingHarnessAndSubsectionOnes() throws {
        let sections = try Self.layout("templates", "template_coder")
        let advanced = try #require(sections.last)

        #expect(advanced.kind == .advanced)
        #expect(advanced.rows.map(\.path) == ["env", "isolation", "harness_options.settings"])
    }

    @Test func subsectionRowsAreAddressedByTheirNestedPath() throws {
        let sections = try Self.layout("templates", "template_coder")

        #expect(sections.first { $0.title == "Permissions" }?.rows.map(\.path) == ["permissions.allow"])
        #expect(sections.first { $0.title == "Push" }?.rows.map(\.path) == ["push.enabled"])
    }

    @Test func theHarnessSectionFollowsTheDraftsCurrentHarness() throws {
        let claude = try Self.layout("templates", "template_coder")
        let codex = try Self.layout("templates", "template_coder") { $0.set("harness", .string("codex")) }

        #expect(claude.first { $0.kind == .harnessOptions }?.rows.map(\.path) == ["harness_options.permission_mode", "harness_options.allowed_tools"])
        #expect(codex.first { $0.kind == .harnessOptions }?.rows.map(\.path) == ["harness_options.sandbox", "harness_options.profile"])
    }

    @Test func switchingTheHarnessMovesItsAdvancedOptionsToo() throws {
        let codex = try Self.layout("templates", "template_coder") { $0.set("harness", .string("codex")) }
        #expect(codex.last?.rows.map(\.path) == ["env", "isolation"])
    }

    @Test func anInheritedHarnessIsUsedWhenTheDraftHasNone() throws {
        let sections = try Self.layout("templates", "template_coder") { $0.set("harness", .string("")) }
        #expect(sections.first { $0.kind == .harnessOptions }?.rows.first?.path == "harness_options.permission_mode")
    }

    @Test func aHarnessWithNoSchemaHasNoOptionsSection() throws {
        let sections = try Self.layout("templates", "template_coder") { $0.set("harness", .string("gemini")) }
        #expect(!sections.contains { $0.kind == .harnessOptions })
    }

    @Test func aResourceWithoutHarnessOptionsHasNoOptionsSection() throws {
        let sections = try Self.layout("web", "web")
        #expect(sections.map(\.kind) == [.group, .advanced])
        #expect(!sections.flatMap(\.rows).contains { $0.path.hasPrefix("harness_options.") })
    }

    @Test func aSectionWithNoRowsIsLeftOut() throws {
        let sections = try Self.layout("client", "client")
        #expect(sections.map(\.title) == ["General"])
    }

    // MARK: rows

    @Test func aRowCarriesItsValueDirtyStateAndErrors() throws {
        let resource = try #require(Self.schema.resource("templates"))
        let validator = LeoConfigValidator(resource: resource, harnesses: Self.schema.harnesses)
        var draft = LeoConfigDraft(document: try LeoConfigFixtures.decode(LeoConfigDocument.self, "template_coder"), validator: validator)
        draft.set("max_turns", .int(0))
        let validated = LeoConfigFormLayout.sections(resource: resource, harnesses: Self.schema.harnesses, draft: draft, references: [:], webLink: nil)
        let row = try #require(validated.flatMap(\.rows).first { $0.path == "max_turns" })

        #expect(row.value == .int(0))
        #expect(row.isDirty)
        #expect(row.errors == ["Must be at least 1"])
        #expect(try #require(validated.flatMap(\.rows).first { $0.path == "workspace" }).isDirty == false)
    }

    @Test func aRowReadsNestedValuesFromTheDocument() throws {
        let rows = try Self.layout("templates", "template_coder").flatMap(\.rows)

        #expect(rows.first { $0.path == "permissions.allow" }?.value == .list([.string("Bash(git status)")]))
        #expect(rows.first { $0.path == "harness_options.allowed_tools" }?.value == .list([.string("Read"), .string("Edit")]))
        #expect(rows.first { $0.path == "harness_options.permission_mode" }?.value == .null)
    }

    @Test func aHarnessOptionsInheritedValueIsItsPlaceholder() throws {
        let rows = try Self.layout("templates", "template_coder").flatMap(\.rows)
        let mode = try #require(rows.first { $0.path == "harness_options.permission_mode" })

        // An enum has no placeholder; the inherited value shows beside it.
        #expect(mode.inherited == .string("acceptEdits"))
    }

    @Test func theModelFieldSuggestsForClaudeAndHintsForCodex() throws {
        func modelControl(_ harness: String) throws -> LeoConfigControl? {
            try Self.layout("templates", "template_coder") { $0.set("harness", .string(harness)) }
                .flatMap(\.rows).first { $0.path == "model" }?.control
        }

        #expect(try modelControl("claude") == .suggestions(["claude-opus-5-5"], placeholder: "inherit: claude-opus-5-5"))
        #expect(try modelControl("codex") == .text(placeholder: "inherit: claude-opus-5-5"))
    }

    @Test func aCodexModelFallsBackToTheHarnessPlaceholderWhenNothingIsInherited() throws {
        let resource = try #require(Self.schema.resource("templates"))
        let document = LeoConfigDocument(revision: "r", name: "x", values: ["harness": .string("codex")], effectiveHarness: "codex")
        let sections = LeoConfigFormLayout.sections(
            resource: resource, harnesses: Self.schema.harnesses, draft: LeoConfigDraft(document: document), references: [:], webLink: nil
        )

        #expect(sections.flatMap(\.rows).first { $0.path == "model" }?.control == .text(placeholder: "e.g. gpt-5.3-codex"))
    }
}
