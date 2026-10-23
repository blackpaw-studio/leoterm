import Foundation
import Testing

@testable import LeoKit

struct LeoConfigSchemaDecodingTests {
    private func decodeSchema(_ json: String) throws -> LeoConfigSchema {
        try JSONDecoder().decode(LeoConfigSchema.self, from: Data(json.utf8))
    }

    @Test(arguments: LeoConfigFixtures.names)
    func everyFixtureIsAWellFormedEnvelope(name: String) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: try LeoConfigFixtures.data(name)) as? [String: Any])
        #expect(object["ok"] is Bool)
    }

    @Test func theSchemaFixtureDecodes() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")

        #expect(schema.schemaVersion == 1)
        #expect(schema.namePattern == "^[A-Za-z0-9._-]+$")
        #expect(schema.resources.map(\.key) == ["defaults", "templates", "tasks", "environments", "web", "client", "hosts"])
        #expect(Set(schema.harnesses.keys) == ["claude", "codex"])
    }

    @Test func aResourceCarriesItsKindActionsAndRestartScope() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let templates = try #require(schema.resource("templates"))

        #expect(templates.kind == .collection)
        #expect(templates.section == "template")
        #expect(templates.actions == [.add, .rename, .duplicate, .delete])
        #expect(templates.harnessOptions)
        #expect(templates.restart == .agents)
        #expect(templates.subsections.map(\.key) == ["permissions", "push"])
        #expect(schema.resource("web")?.restart == .service)
        #expect(schema.resource("tasks")?.restart == LeoConfigRestartScope.none)
        #expect(schema.resource("web")?.kind == .singleton)
        #expect(schema.resource("nope") == nil)
    }

    @Test func aFieldCarriesItsTypeExtrasAndConstraints() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let templates = try #require(schema.resource("templates"))

        let maxTurns = try #require(templates.field("max_turns"))
        #expect(maxTurns.type == .int)
        #expect(maxTurns.constraints.min == 1)
        #expect(maxTurns.constraints.max == 1000)
        #expect(maxTurns.defaultValue == .null)

        let workspace = try #require(templates.field("workspace"))
        #expect(workspace.constraints.required)
        #expect(workspace.help == "Directory agents start in.")
        #expect(workspace.group == "General")
        #expect(!workspace.advanced)

        #expect(templates.field("system_prompt")?.multiline == true)
        #expect(templates.field("idle_suspend")?.nullable == true)
        #expect(templates.field("idle_timeout")?.type == .duration)
        #expect(templates.field("idle_timeout")?.defaultValue == .string("30m"))
        #expect(templates.field("env")?.type == .map)
        #expect(templates.field("env")?.advanced == true)
        #expect(templates.field("env")?.warning == "Values are stored in leo.yaml in plain text.")

        let harness = try #require(templates.field("harness"))
        #expect(harness.type == .enum)
        #expect(harness.options.map(\.value) == ["", "claude", "codex"])
        #expect(harness.options.last?.label == "Codex")
    }

    @Test func modelHintsAreKeyedByHarness() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let model = try #require(schema.resource("templates")?.field("model"))

        #expect(model.hintsByHarness["claude"]?.suggestions == ["claude-opus-5-5"])
        #expect(model.hintsByHarness["codex"]?.placeholder == "e.g. gpt-5.3-codex")
    }

    @Test func cronReferenceAndSecretFieldsDecode() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let tasks = try #require(schema.resource("tasks"))

        #expect(tasks.field("schedule")?.format == "cron")
        #expect(tasks.field("schedule")?.constraints.required == true)
        #expect(tasks.field("template")?.type == .reference)
        #expect(tasks.field("template")?.references == "templates")
        #expect(tasks.field("template")?.emptyLabel == "none")
        #expect(schema.resource("hosts")?.field("token")?.type == .secret)
        #expect(schema.resource("hosts")?.field("address")?.constraints.pattern == "^[^\\s]+$")
    }

    @Test func harnessSchemasDecodeIncludingYAMLOptions() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")

        #expect(schema.harnesses["claude"]?.fields.map(\.key) == ["permission_mode", "allowed_tools", "settings"])
        #expect(schema.harnesses["claude"]?.fields.last?.type == .yaml)
        #expect(schema.harnesses["codex"]?.fields.first?.options.map(\.value) == ["", "workspace-write"])
    }

    @Test func anUnknownTypeDecodesAsUnknownAndDoesNotFail() throws {
        let schema = try decodeSchema("""
        {"schema_version": 1, "name_pattern": "", "harnesses": {}, "resources": [
          {"key": "web", "label": "Web", "kind": "singleton", "section": "web", "actions": [], "fields": [
            {"key": "tint", "label": "Tint", "type": "color"}]}]}
        """)
        let field = try #require(schema.resource("web")?.field("tint"))

        #expect(field.type == .unknown("color"))
        #expect(field.label == "Tint")
    }

    @Test func unknownKeysKindsActionsAndRestartScopesAreIgnoredOrKept() throws {
        let schema = try decodeSchema("""
        {"schema_version": 7, "future": {"x": 1}, "resources": [
          {"key": "widgets", "label": "Widgets", "kind": "tree", "section": "widget", "restart": "reboot",
           "actions": ["add", "teleport"], "sparkles": true,
           "fields": [{"key": "a", "label": "A", "type": "string", "sparkles": [1, 2]}]}]}
        """)
        let widgets = try #require(schema.resource("widgets"))

        #expect(widgets.kind == .other("tree"))
        #expect(widgets.restart == .other("reboot"))
        #expect(widgets.actions == [.add])
        #expect(widgets.field("a")?.type == .string)
    }

    @Test func missingOptionalPartsTakeDefaults() throws {
        let schema = try decodeSchema(#"{"resources": [{"key": "r", "label": "R", "fields": [{"key": "a", "type": "bool"}]}]}"#)
        let field = try #require(schema.resource("r")?.field("a"))

        #expect(schema.schemaVersion == 1)
        #expect(schema.resource("r")?.subsections.isEmpty == true)
        #expect(field.label == "a")
        #expect(field.options.isEmpty)
        #expect(!field.constraints.required)
        #expect(field.defaultValue == .null)
    }

    @Test func documentsDecodeValuesInheritedAndHarness() throws {
        let document = try LeoConfigFixtures.decode(LeoConfigDocument.self, "template_coder")

        #expect(document.revision == "sha256:aa11")
        #expect(document.name == "coder")
        #expect(document.effectiveHarness == "claude")
        #expect(document.values["max_turns"] == .null)
        #expect(document.values["idle_timeout"] == .string("45m"))
        #expect(document.values["environments"] == .list([.string("work"), .string("secrets")]))
        #expect(document.values["env"] == .map(["FOO": "bar"]))
        #expect(document.values["harness_options"]?.objectValue?["allowed_tools"] == .list([.string("Read"), .string("Edit")]))
        #expect(document.values["push"]?.objectValue?["enabled"] == .bool(false))
        #expect(document.inherited["model"] == .string("claude-opus-5-5"))
    }

    @Test func singletonDocumentsHaveNoName() throws {
        for name in ["defaults", "web", "client"] {
            let document = try LeoConfigFixtures.decode(LeoConfigDocument.self, name)
            #expect(document.name == nil)
            #expect(document.revision.hasPrefix("sha256:"))
        }
        #expect(try LeoConfigFixtures.decode(LeoConfigDocument.self, "web").values["port"] == .int(8370))
    }

    @Test(arguments: ["templates", "tasks", "environments", "hosts"])
    func collectionsDecodeItemsInOrder(name: String) throws {
        let collection = try LeoConfigFixtures.decode(LeoConfigCollection.self, name)

        #expect(collection.revision == "sha256:aa11")
        #expect(!collection.items.isEmpty)
        #expect(collection.items.map(\.name) == collection.items.map(\.name).sorted())
    }

    @Test func aHostSecretReadsAsSetOrNotSet() throws {
        let hosts = try LeoConfigFixtures.decode(LeoConfigCollection.self, "hosts")

        #expect(hosts.items.first?.values["token"] == .secret(isSet: true))
        #expect(hosts.items.last?.values["token"] == .secret(isSet: false))
    }

    @Test func aWriteResultCarriesTheRevisionRestartFlagsAndWarning() throws {
        let result = try LeoConfigFixtures.decode(LeoConfigWriteResult.self, "write_result")

        #expect(result.revision == "sha256:bb22")
        #expect(result.restartRequired == LeoConfigRestartRequired(service: false, agents: true))
        #expect(result.warning == "saved, but reload failed: boom")
        #expect(result.item?.name == "coder")
    }

    @Test func aWriteResultWithoutOptionalPartsDecodes() throws {
        let result = try JSONDecoder().decode(LeoConfigWriteResult.self, from: Data(#"{"revision":"sha256:1"}"#.utf8))
        #expect(result.restartRequired == LeoConfigRestartRequired(service: false, agents: false))
        #expect(result.warning == nil)
        #expect(result.item == nil)
    }
}
